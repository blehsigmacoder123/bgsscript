local CONFIG = {
    PetName = "Ancient Immortal One",
    Webhook = (getgenv and getgenv() or _G).ASSET_EXPORT_WEBHOOK or "",
    LoadTimeout = 60,
    ExportTimeout = 120,
    MaxModelBytes = 6 * 1024 * 1024,

    MaxZipBytes = 8 * 1024 * 1024,
    YieldEveryBytes = 32768,
    RetryLimit = 4,
    MaxRetryWait = 60,
}

local started = os.clock()
local lines = {}
local stage = "BOOT"
local idleConnection, exportTask, clone
local outputPrefix
local HttpService = game:GetService("HttpService")
local function log(level, message)
    local line = string.format("[PET EXPORT][%07.2fs][%s][%s] %s",
        os.clock() - started, stage, level, tostring(message))
    table.insert(lines, line)
    if level == "ERROR" or level == "WARN" then warn(line) else print(line) end
end
local function step(name, message)
    stage = name
    log("INFO", message)
end
local function requireThat(condition, message)
    if not condition then error(message, 0) end
end
local function redact(value)
    local s = tostring(value)
    s = s:gsub("https://discord%.com/api/webhooks/[^%s\"<>]+", "[REDACTED WEBHOOK]")
    return s
end
local function waitUntil(predicate, seconds, message)
    local deadline = os.clock() + seconds
    repeat
        if predicate() then return end
        task.wait(0.2)
    until os.clock() >= deadline
    error(message, 0)
end


local HttpRequest = (syn and syn.request) or (http and http.request)
    or http_request or (fluxus and fluxus.request) or request
local NativeSave = saveinstance or (syn and syn.saveinstance)



local function unescapeXML(s)
    return (s:gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end
local function xmlItems(xml)
    requireThat(xml:find("<roblox", 1, true) and xml:find("</roblox>", 1, true),
        "SERIALIZER_FORMAT: expected Roblox XML. Binary or truncated output is unsupported.")
    local roots, stack, all = {}, {}, {}
    local position, iterations = 1, 0
    while true do
        local first, last, tag = xml:find("(<[^>]+>)", position)
        if not first then break end
        if tag:match("^<Item%s") then
            local class = tag:match('class="([^"]+)"')
            local referent = tag:match('referent="([^"]+)"')
            requireThat(class and referent, "XML_STRUCTURE: Item lacks class or referent.")
            local item = {class = class, referent = referent, children = {}, start = last + 1}
            if #stack == 0 then table.insert(roots, item)
            else
                local parent = stack[#stack]

                if not parent.properties then
                    parent.properties = xml:sub(parent.start, first - 1)
                end
                table.insert(parent.children, item)
            end
            table.insert(all, item)
            table.insert(stack, item)
        elseif tag == "</Item>" then
            requireThat(#stack > 0, "XML_STRUCTURE: unmatched Item close tag.")
            local item = table.remove(stack)
            item.properties = item.properties or xml:sub(item.start, first - 1)
            local rawName = item.properties:match('<string%s+name="Name">(.-)</string>')
            requireThat(rawName ~= nil, "XML_STRUCTURE: missing instance Name.")
            item.name = unescapeXML(rawName)
        end
        position = last + 1
        iterations = iterations + 1
        if iterations % 400 == 0 then task.wait() end
    end
    requireThat(#stack == 0, "XML_STRUCTURE: unclosed Item tags.")
    return roots, all
end


local function signature(class, name, children)
    table.sort(children)
    return string.format("%d:%s%d:%s[%s]", #class, class, #name, name,
        table.concat(children, ";"))
end
local function instanceSignature(instance)
    local children = {}
    for _, child in ipairs(instance:GetChildren()) do
        table.insert(children, instanceSignature(child))
    end
    return signature(instance.ClassName, instance.Name, children)
end
local function itemSignature(item)
    local children = {}
    for _, child in ipairs(item.children) do table.insert(children, itemSignature(child)) end
    return signature(item.class, item.name, children)
end

local ASSET_PROPERTIES = {
    "MeshId", "TextureID", "TextureId", "Texture", "ColorMap", "NormalMap",
    "MetalnessMap", "RoughnessMap", "AnimationId", "SoundId",
}
local function inventory(root)
    local nodes = {root}
    for _, node in ipairs(root:GetDescendants()) do table.insert(nodes, node) end
    local result = {instanceCount = #nodes, classes = {}, assets = {}, attributes = {}, scripts = {}}
    for index, node in ipairs(nodes) do
        result.classes[node.ClassName] = (result.classes[node.ClassName] or 0) + 1
        local path = node:GetFullName()
        local attributes = {}
        for key, value in pairs(node:GetAttributes()) do
            attributes[key] = {type = typeof(value), value = tostring(value)}
        end
        if next(attributes) then
            table.insert(result.attributes, {path = path, values = attributes})
        end
        if node:IsA("LuaSourceContainer") then table.insert(result.scripts, path) end
        for _, property in ipairs(ASSET_PROPERTIES) do
            local ok, value = pcall(function() return node[property] end)
            if ok and type(value) == "string" and value ~= "" then
                table.insert(result.assets, {path = path, property = property, value = value})
            end
        end
        if index % 25 == 0 then task.wait() end
    end
    return result
end

local function referenceFingerprint(class, name, children, urls, hasAttributes)
    table.sort(urls)
    return signature(class, name, children) .. "{" .. table.concat(urls, ";") .. "}"
        .. (hasAttributes and "ATTR" or "")
end
local function sourceFingerprint(node, knownURLs)
    local children, unique, urls = {}, {}, {}
    for _, child in ipairs(node:GetChildren()) do
        table.insert(children, sourceFingerprint(child, knownURLs))
    end
    for _, property in ipairs(ASSET_PROPERTIES) do
        local ok, value = pcall(function() return node[property] end)
        if ok and type(value) == "string" and value ~= "" and not unique[value] then
            unique[value] = true
            knownURLs[value] = true
            table.insert(urls, value)
        end
    end
    return referenceFingerprint(node.ClassName, node.Name, children, urls, next(node:GetAttributes()) ~= nil)
end
local function exportedFingerprint(item, knownURLs)
    local children, urls = {}, {}
    for _, child in ipairs(item.children) do
        table.insert(children, exportedFingerprint(child, knownURLs))
    end
    local found = {}

    for raw in item.properties:gmatch(">([^<>]*)<") do
        local value = unescapeXML(raw)
        if knownURLs[value] and not found[value] then
            found[value] = true
            table.insert(urls, value)
        end
    end
    local attributes = item.properties:match('<BinaryString%s+name="AttributesSerialize">(.-)</BinaryString>')
    local encoded = attributes and attributes:gsub("<!%[CDATA%[", ""):gsub("%]%]>", ""):gsub("%s", "") or ""

    local hasAttributes = encoded ~= "" and encoded:sub(1, 6) ~= "AAAAAA"
    return referenceFingerprint(item.class, item.name, children, urls, hasAttributes)
end



local crcTable = {}
local function initializeCRC()
    for n = 0, 255 do
        local c = n
        for _ = 1, 8 do
            c = bit32.bxor(bit32.rshift(c, 1), c % 2 == 1 and 0xEDB88320 or 0)
        end
        crcTable[n] = c
    end
end
local function crc32(data)
    local crc = 0xFFFFFFFF
    for i = 1, #data do
        crc = bit32.bxor(bit32.rshift(crc, 8),
            crcTable[bit32.band(bit32.bxor(crc, data:byte(i)), 255)])
        if i % CONFIG.YieldEveryBytes == 0 then task.wait() end
    end
    return bit32.bxor(crc, 0xFFFFFFFF)
end
local function u16(n)
    return string.char(n % 256, math.floor(n / 256) % 256)
end
local function u32(n)
    return u16(n % 65536) .. u16(math.floor(n / 65536))
end
local function buildZip(files)
    local localChunks, directory, offset, checksums = {}, {}, 0, {}
    for _, file in ipairs(files) do
        local name, data = file.name, file.data
        requireThat(#name < 65536 and #data < 4294967296, "ZIP_LIMIT: ZIP64 is unsupported.")
        local crc = crc32(data)
        checksums[name] = string.format("%08x", crc)

        local header = "PK\003\004" .. u16(20) .. u16(0) .. u16(0)
            .. u16(0) .. u16(33) .. u32(crc) .. u32(#data) .. u32(#data)
            .. u16(#name) .. u16(0) .. name
        table.insert(localChunks, header)
        table.insert(localChunks, data)
        table.insert(directory, "PK\001\002" .. u16(20) .. u16(20) .. u16(0)
            .. u16(0) .. u16(0) .. u16(33) .. u32(crc) .. u32(#data) .. u32(#data)
            .. u16(#name) .. u16(0) .. u16(0) .. u16(0) .. u16(0) .. u32(0)
            .. u32(offset) .. name)
        offset = offset + #header + #data
        log("INFO", string.format("ZIP entry %s: %d bytes; CRC32 %08x", name, #data, crc))
    end
    local central = table.concat(directory)
    table.insert(localChunks, central)
    table.insert(localChunks, "PK\005\006" .. u16(0) .. u16(0) .. u16(#files)
        .. u16(#files) .. u32(#central) .. u32(offset) .. u16(0))
    return table.concat(localChunks), checksums
end

local function readExport(path)
    if not isfile(path) then return nil end
    local ok, data = pcall(readfile, path)
    if ok and type(data) == "string" and #data > 0 then return data end
    return nil
end

local function nativeExport(root, prefix)
    local path = prefix .. ".rbxmx"
    local complete, failure = false, nil
    log("INFO", "Calling native saveinstance for an isolated, unparented clone.")


    exportTask = task.spawn(function()
        local ok, err = pcall(NativeSave, {
            Object = root,
            FilePath = path,
            Mode = "full",
            SaveAsBinary = false,


            Decompile = false,
            SaveScripts = false,
            ShowStatus = false,
        })
        if not ok then failure = redact(err) end
        complete = true
    end)
    local deadline, nextHeartbeat = os.clock() + CONFIG.ExportTimeout, os.clock() + 5
    local lastData, stable = nil, 0
    while os.clock() < deadline do
        if failure then error("NATIVE_EXPORT: " .. failure, 0) end

        for _, candidate in ipairs({path, path .. ".rbxmx", path .. ".rbxlx", prefix .. ".rbxlx"}) do
            local data = readExport(candidate)
            if data then
                requireThat(#data <= CONFIG.MaxModelBytes, "MODEL_SIZE: exceeds configured memory budget.")
                if data == lastData then stable = stable + 1 else stable = 0 end
                lastData = data

                if complete and stable >= 3 and data:find("</roblox>%s*$") then
                    log("INFO", "Native file completed: " .. candidate .. " (" .. #data .. " bytes).")
                    exportTask = nil
                    return data
                end
            end
        end
        if os.clock() >= nextHeartbeat then
            log("INFO", "Waiting for native XML output; elapsed " ..
                string.format("%.1f", CONFIG.ExportTimeout - (deadline - os.clock())) .. " seconds.")
            nextHeartbeat = os.clock() + 5
        end
        task.wait(0.5)
    end
    error("NATIVE_TIMEOUT: no completed XML file. This executor may ignore Object/FilePath/SaveAsBinary, " ..
        "lack XML serialization, or export asynchronously beyond the timeout. Nothing uploaded.", 0)
end

local function upload(zip, filename)
    local boundary = "PetExport" .. HttpService:GenerateGUID(false):gsub("%-", "")
    while zip:find(boundary, 1, true) do boundary = boundary .. "x" end
    local payload = HttpService:JSONEncode({
        content = "Ancient Immortal One model export: Roblox XML, asset-reference inventory, and export log.",
        allowed_mentions = {parse = {}},
        attachments = {{id = 0, filename = filename, description = "Roblox-importable pet model ZIP"}},
    })
    local body = "--" .. boundary .. '\r\nContent-Disposition: form-data; name="payload_json"\r\n'
        .. "Content-Type: application/json\r\n\r\n" .. payload .. "\r\n--" .. boundary
        .. '\r\nContent-Disposition: form-data; name="files[0]"; filename="' .. filename .. '"\r\n'
        .. "Content-Type: application/zip\r\n\r\n" .. zip .. "\r\n--" .. boundary .. "--\r\n"
    local url = CONFIG.Webhook .. "?wait=true"
    for attempt = 1, CONFIG.RetryLimit do
        log("INFO", string.format("Discord POST attempt %d/%d; ZIP %d bytes; multipart %d bytes.",
            attempt, CONFIG.RetryLimit, #zip, #body))
        local ok, response = pcall(HttpRequest, {
            Url = url, Method = "POST",
            Headers = {["Content-Type"] = "multipart/form-data; boundary=" .. boundary},
            Body = body,
        })


        requireThat(ok, "HTTP_TRANSPORT: " .. redact(response) .. ". ZIP saved locally; check Discord before rerunning.")
        requireThat(type(response) == "table", "HTTP_RESPONSE: executor returned no response table.")
        local status = tonumber(response.StatusCode or response.Status or response.status_code)
        local responseBody = tostring(response.Body or response.body or "")
        log("INFO", "Discord HTTP status: " .. tostring(status))
        if status == 200 then
            local decodedOK, decoded = pcall(HttpService.JSONDecode, HttpService, responseBody)
            requireThat(decodedOK and type(decoded) == "table" and decoded.id,
                "DISCORD_RECEIPT: HTTP 200 without a readable message receipt; check Discord before rerunning.")
            local attachmentFound = false
            for _, attachment in ipairs(decoded.attachments or {}) do
                if attachment.filename == filename and tonumber(attachment.size) == #zip then
                    attachmentFound = true
                end
            end
            requireThat(attachmentFound, "DISCORD_ATTACHMENT: receipt does not confirm the expected ZIP size/name.")
            log("INFO", "Discord confirmed attachment; message ID " .. tostring(decoded.id))
            return
        elseif status == 429 and attempt < CONFIG.RetryLimit then
            local decodedOK, decoded = pcall(HttpService.JSONDecode, HttpService, responseBody)
            local delay = decodedOK and type(decoded) == "table" and tonumber(decoded.retry_after) or nil
            requireThat(delay and delay >= 0 and delay <= CONFIG.MaxRetryWait,
                "DISCORD_RATE_LIMIT: missing or excessive retry_after; ZIP saved locally.")
            log("WARN", string.format("Rate limited; retrying in %.2f seconds.", delay + 0.25))
            task.wait(delay + 0.25)
        else
            error("DISCORD_REJECTED: HTTP " .. tostring(status) .. "; response: " ..
                redact(responseBody:sub(1, 1800)) .. ". 413 means upload too large; " ..
                "401/403/404 may indicate an invalid or inaccessible webhook. ZIP saved locally.", 0)
        end
    end
    error("DISCORD_RETRIES: rate-limit attempts exhausted. ZIP saved locally.", 0)
end

local README = [[Ancient Immortal One â€” Roblox model export

Extract this ZIP. In Roblox Studio, use Insert from File to insert
Ancient_Immortal_One.rbxmx into Workspace or your desired parent.
Keep Roblox asset permissions/network access available for meshes and textures.
This archive references Roblox assets; it does not contain offline mesh/image data.

The native model serializer handles colors, transforms, decals, attachments,
particle settings, instance references, and attributes. The exporter checks the
instance hierarchy and asset URLs, but cannot prove every hidden property survived.
Inspect the result visually in Studio before relying on identical appearance.

Attributes such as Animation="Fly" are metadata. External game animation,
follow logic, scripted emission bursts, and lighting are not included. Enabled
particle emitters run in Studio; disabled emitters may require the game's code.

manifest.json records the source inventory and validation results.
export.log contains progress up to ZIP construction. The complete upload result
and any failure traceback are saved beside the ZIP in the executor filesystem.
No third-party serializer is fetched. Native executor serialization is required.
]]

local function run()
    step("01 PREFLIGHT", "Checking executor capabilities before changing or exporting anything.")
    local missing = {}
    for name, fn in pairs({HttpRequest = HttpRequest or false, saveinstance = NativeSave or false,
        readfile = readfile or false, writefile = writefile or false, isfile = isfile or false}) do
        if type(fn) ~= "function" then table.insert(missing, name) end
    end
    table.sort(missing)
    requireThat(#missing == 0, "CAPABILITY_MISSING: " .. table.concat(missing, ", ") ..
        ". This Delta/executor build cannot run the faithful native export. " ..
        "No partial substitute or remote serializer will be used.")
    requireThat(bit32 ~= nil, "CAPABILITY_MISSING: bit32 required for ZIP CRC32.")
    requireThat(type(CONFIG.Webhook) == "string" and
        CONFIG.Webhook:match("^https://discord%.com/api/webhooks/%d+/[%w_%-]+$"),
        "WEBHOOK_FORMAT: expected a clean Discord webhook URL, without a trailing comma.")
    initializeCRC()
    requireThat(crc32("123456789") == 0xCBF43926, "ZIP_SELF_TEST: CRC32 reference vector failed.")
    outputPrefix = "Ancient_Immortal_One_" .. HttpService:GenerateGUID(false):gsub("%-", "")

    step("02 LOAD", "Waiting for game and local player, with a bounded timeout.")
    waitUntil(function() return game:IsLoaded() end, CONFIG.LoadTimeout, "GAME_TIMEOUT: game did not load.")
    local players = game:GetService("Players")
    waitUntil(function() return players.LocalPlayer ~= nil end, CONFIG.LoadTimeout,
        "PLAYER_TIMEOUT: run this in a game client, not a server/Studio edit environment.")
    local virtualUser = game:GetService("VirtualUser")
    local reportedIdleFailure = false
    idleConnection = players.LocalPlayer.Idled:Connect(function()
        local ok, err = pcall(function()
            virtualUser:CaptureController()
            virtualUser:ClickButton2(Vector2.new(0, 0))
        end)
        if ok then log("INFO", "Anti-AFK idle input sent.")
        elseif not reportedIdleFailure then
            reportedIdleFailure = true
            log("WARN", "Anti-AFK unavailable: " .. redact(err))
        end
    end)
    log("INFO", "Anti-AFK connected for this export; disconnects on completion/failure.")

    step("03 LOCATE", 'Resolving ReplicatedStorage.Assets.Pets.Normal["' .. CONFIG.PetName .. '"].')
    local target = game:GetService("ReplicatedStorage")
    for _, name in ipairs({"Assets", "Pets", "Normal", CONFIG.PetName}) do
        local nextTarget = target:FindFirstChild(name) or target:WaitForChild(name, CONFIG.LoadTimeout)
        requireThat(nextTarget, "TARGET_MISSING: '" .. name .. "' under " .. target:GetFullName())
        target = nextTarget
    end
    requireThat(target:IsA("Model"), "TARGET_CLASS: expected Model, got " .. target.ClassName)
    local source = inventory(target)
    log("INFO", "Found " .. target:GetFullName() .. "; " .. source.instanceCount .. " total instances.")
    for class, count in pairs(source.classes) do log("INFO", class .. " = " .. count) end
    log("INFO", #source.assets .. " nonempty asset-property references recorded.")
    requireThat(#source.scripts == 0, "SCRIPT_DEPENDENCY: target contains scripts; faithful source export " ..
        "cannot be guaranteed by this serializer configuration. Nothing uploaded.")

    step("04 SNAPSHOT", "Cloning the complete pet; original model is never edited.")
    requireThat(target.Archivable, "NOT_ARCHIVABLE: source model cannot be cloned without editing it.")
    clone = target:Clone()
    requireThat(clone ~= nil, "CLONE_FAILED: model Clone returned nil.")
    local sourceSignature = instanceSignature(target)
    requireThat(instanceSignature(clone) == sourceSignature,
        "CLONE_INCOMPLETE: an unarchivable child or concurrent source change altered the hierarchy.")
    local snapshot = inventory(clone)
    local knownURLs = {}
    local expectedFingerprint = sourceFingerprint(clone, knownURLs)

    snapshot.sourcePath = target:GetFullName()
    snapshot.format = "Roblox XML model + ZIP STORE"
    snapshot.embeddedAssetBinaries = false
    snapshot.externalGameCodeIncluded = false
    snapshot.exportedAtUTC = os.date("!%Y-%m-%dT%H:%M:%SZ")

    step("05 SERIALIZE", "Exporting isolated model through native saveinstance.")
    log("WARN", "Native serializer performance is executor-controlled; Lua cannot guarantee it never stalls.")
    local xml = nativeExport(clone, outputPrefix)

    step("06 VALIDATE", "Checking XML format, exact scoped hierarchy, attributes, and asset references.")
    local roots, all = xmlItems(xml)
    requireThat(#roots == 1, "EXPORT_SCOPE: expected one root model; got " .. #roots .. ". Nothing uploaded.")
    requireThat(#all == snapshot.instanceCount and itemSignature(roots[1]) == sourceSignature,
        "EXPORT_HIERARCHY: serializer output does not match the target subtree. Nothing uploaded.")
    requireThat(exportedFingerprint(roots[1], knownURLs) == expectedFingerprint,
        "EXPORT_PROPERTIES: asset URLs or nonempty attributes are missing/misplaced on individual instances. Nothing uploaded.")
    local referents = {}
    for _, item in ipairs(all) do
        requireThat(not referents[item.referent], "XML_REFERENT: duplicate referent " .. item.referent)
        referents[item.referent] = true
    end
    for ref in xml:gmatch('<Ref%s+name="[^"]+">(.-)</Ref>') do
        requireThat(ref == "null" or ref == "nil" or referents[ref],
            "EXTERNAL_REFERENCE: XML references an instance outside this model: " .. ref)
    end


    local decodedXML = unescapeXML(xml)
    for _, asset in ipairs(snapshot.assets) do
        requireThat(decodedXML:find(asset.value, 1, true),
            "ASSET_REFERENCE_MISSING: " .. asset.property .. " at " .. asset.path .. " -> " .. asset.value)
    end
    if #snapshot.attributes > 0 then
        requireThat(xml:find('name="AttributesSerialize"', 1, true),
            "ATTRIBUTES_MISSING: native output lacks serialized attributes.")
    end
    snapshot.validation = {hierarchyMatched = true, assetURLsPresent = true,
        instanceCount = #all, hiddenPropertiesVerified = false, visuallyVerified = false}
    log("INFO", "Passed: one pet root, exact hierarchy, internal referents, per-instance asset URLs and attribute field presence.")
    log("WARN", "Asset permissions, external game animation, and visual fidelity require a Studio import check.")

    step("07 ZIP", "Building four-file ZIP with yielded CRC32 calculations.")
    local manifest = HttpService:JSONEncode(snapshot)
    local zip = buildZip({
        {name = "Ancient_Immortal_One.rbxmx", data = xml},
        {name = "manifest.json", data = manifest},
        {name = "README.txt", data = README},
        {name = "export.log", data = table.concat(lines, "\n") .. "\n"},
    })
    requireThat(#zip <= CONFIG.MaxZipBytes, "ZIP_SIZE: archive exceeds configured upload/memory budget.")
    local zipPath = outputPrefix .. ".zip"
    writefile(zipPath, zip)
    requireThat(readfile(zipPath) == zip, "FILESYSTEM_CORRUPTION: ZIP readback differs from generated bytes.")
    log("INFO", "ZIP written and byte-verified: " .. zipPath .. " (" .. #zip .. " bytes).")

    step("08 UPLOAD", "Uploading ZIP as a binary multipart Discord attachment.")
    upload(zip, "Ancient_Immortal_One.zip")
    step("09 DONE", "Discord confirmed ZIP receipt. Local backup: " .. zipPath)
end

local ok, failure = xpcall(run, function(err)
    return debug.traceback(redact(err), 2)
end)
if not ok then log("ERROR", failure) end

if idleConnection then idleConnection:Disconnect() end
if exportTask then pcall(task.cancel, exportTask) end
if clone then pcall(function() clone:Destroy() end) end
if type(writefile) == "function" then
    local logPath = (outputPrefix or "Ancient_Immortal_One_failed") .. ".log"
    local saved, err = pcall(writefile, logPath, table.concat(lines, "\n") .. "\n")
    if saved then log("INFO", "Complete console log saved: " .. logPath)
    else log("WARN", "Cannot save log: " .. redact(err)) end
end
if not ok then warn("[PET EXPORT] FAILED. See the ERROR stage and traceback above. No success is claimed.") end


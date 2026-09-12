--[[
* bindview - A read-only keybind overlay for Ashita v4.
*
* Watches every /bind and /unbind command that passes through Ashita's command
* pipeline (including the ones LuAshitacast profiles queue on load) and shows the
* current binds as a grid of action icons with the key drawn on each slot.
* It never sets, blocks, or executes a bind itself.
*
* Load it BEFORE luashitacast so the profile's SetBindings() calls are seen.
*
* Icons: resources/spells/<index>.png, resources/abilities/<id-512>.png,
*        resources/abilities/1hr.png, resources/misc/command.png (from tHotBar).
--]]

addon.name      = 'bindview';
addon.author    = 'Plinx';
addon.version   = '0.2.0';
addon.desc      = 'Shows your current /bind keybinds as an icon grid.';

require('common');
local chat     = require('chat');
local imgui    = require('imgui');
local settings = require('settings');
local d3d8     = require('d3d8');
local ffi      = require('ffi');

-- ============================================
-- Settings
-- ============================================

local defaultSettings = T{
    visible    = true,
    locked     = false,
    columns    = 6,
    iconSize   = 36,
    padding    = 4,
    alpha      = 0.35,
    keyScale   = 1.0,
    showNames  = false,
    showTarget = false,
    showRecast = true,
    layout     = 'keyboard',   -- 'keyboard' or 'grid'
    showEmptyKeys = true,      -- keyboard mode: draw faint slots for unbound keys
    keyBadge   = true,         -- solid dark badge behind the key label
    keyColor   = T{ 1.0, 0.95, 0.55, 1.0 },   -- key label color (RGBA 0-1)
    showProfileName = true,    -- draw the active profile name above the slots
    currentProfile = '',       -- last profile loaded through bindview
    position_x = 40,
    position_y = 300,
    -- Commands that are bound by the launcher / system and are not actions.
    -- A bind whose command starts with one of these is hidden.
    ignore     = T{ '/ashita', '/screenshot', '/paste', '/ambient', '/fps', '/ta ', '/bindview' },
    -- Manual icon choices, keyed by lowercase bind key: { kind = 'spell'|'ability'|'item'|'misc', value = <index|id|filename> }
    iconOverrides = T{},
};

local bv = T{
    settings = settings.load(defaultSettings),
    -- Ordered list of { key, label, command, action, hidden, icon }
    binds    = T{},
    -- lowercase key -> index into binds
    index    = {},
    positionApplied = false,
    configOpen = false,
};

local function SaveSettings()
    settings.save();
end

-- Config window widget buffers (ImGui wants tables it can write into)
local cfg = {
    visible    = { true },
    locked     = { false },
    columns    = { 6 },
    iconSize   = { 36 },
    padding    = { 4 },
    alpha      = { 0.35 },
    keyScale   = { 1.0 },
    showNames  = { false },
    showTarget = { false },
    showRecast = { true },
    showEmptyKeys = { true },
    layoutIndex = { 1 },
    keyBadge   = { true },
    keyColor   = { 1.0, 0.95, 0.55, 1.0 },
    showProfileName = { true },
};

local LAYOUT_NAMES = T{ 'Keyboard', 'Grid' };
local LAYOUT_VALUES = T{ 'keyboard', 'grid' };

local function SyncConfigFromSettings()
    local s = bv.settings;
    cfg.visible[1]    = s.visible;
    cfg.locked[1]     = s.locked;
    cfg.columns[1]    = s.columns;
    cfg.iconSize[1]   = s.iconSize;
    cfg.padding[1]    = s.padding;
    cfg.alpha[1]      = s.alpha;
    cfg.keyScale[1]   = s.keyScale;
    cfg.showNames[1]  = s.showNames;
    cfg.showTarget[1] = s.showTarget;
    cfg.showRecast[1] = (s.showRecast ~= false);
    cfg.showEmptyKeys[1] = (s.showEmptyKeys ~= false);
    cfg.layoutIndex[1] = (s.layout == 'grid') and 2 or 1;
    cfg.keyBadge[1] = (s.keyBadge ~= false);
    cfg.showProfileName[1] = (s.showProfileName ~= false);
    local kc = s.keyColor or defaultSettings.keyColor;
    cfg.keyColor[1], cfg.keyColor[2], cfg.keyColor[3], cfg.keyColor[4] = kc[1], kc[2], kc[3], kc[4];
end

local function SyncSettingsFromConfig()
    local s = bv.settings;
    s.visible    = cfg.visible[1];
    s.locked     = cfg.locked[1];
    s.columns    = cfg.columns[1];
    s.iconSize   = cfg.iconSize[1];
    s.padding    = cfg.padding[1];
    s.alpha      = cfg.alpha[1];
    s.keyScale   = cfg.keyScale[1];
    s.showNames  = cfg.showNames[1];
    s.showTarget = cfg.showTarget[1];
    s.showRecast = cfg.showRecast[1];
    s.showEmptyKeys = cfg.showEmptyKeys[1];
    s.layout     = LAYOUT_VALUES[cfg.layoutIndex[1]] or 'keyboard';
    s.keyBadge   = cfg.keyBadge[1];
    s.keyColor   = T{ cfg.keyColor[1], cfg.keyColor[2], cfg.keyColor[3], cfg.keyColor[4] };
    s.showProfileName = cfg.showProfileName[1];
end

settings.register('settings', 'settings_update', function(s)
    if s ~= nil then
        bv.settings = s;
    end
    bv.positionApplied = false;
    SyncConfigFromSettings();
    SaveSettings();
end);

SyncConfigFromSettings();

-- ============================================
-- Textures
-- ============================================

local textureCache = {};   -- cache key -> { Texture, Width, Height } or false when missing

local function ResourcePath(relative)
    return string.format('%saddons\\%s\\resources\\%s', AshitaCore:GetInstallPath(), addon.name, relative);
end

local function LoadTextureFromFile(path)
    if not ashita.fs.exists(path) then
        return nil;
    end
    local device = d3d8.get_device();
    if device == nil then return nil; end

    local ptr = ffi.new('IDirect3DTexture8*[1]');
    if ffi.C.D3DXCreateTextureFromFileA(device, path, ptr) ~= ffi.C.S_OK then
        return nil;
    end
    local texture = d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', ptr[0]));
    local result, desc = texture:GetLevelDesc(0);
    if result ~= 0 then return nil; end
    return { Texture = texture, Width = desc.Width, Height = desc.Height };
end

local function LoadItemTexture(itemId)
    local item = AshitaCore:GetResourceManager():GetItemById(itemId);
    if item == nil then return nil; end
    local device = d3d8.get_device();
    if device == nil then return nil; end

    local size = -1;
    if ashita.interface_version == nil then
        size = item.ImageSize;
    end
    local ptr = ffi.new('IDirect3DTexture8*[1]');
    local ok = ffi.C.D3DXCreateTextureFromFileInMemoryEx(
        device, item.Bitmap, size, 0xFFFFFFFF, 0xFFFFFFFF, 1, 0,
        ffi.C.D3DFMT_A8R8G8B8, ffi.C.D3DPOOL_MANAGED, ffi.C.D3DX_DEFAULT, ffi.C.D3DX_DEFAULT,
        0xFF000000, nil, nil, ptr);
    if ok ~= ffi.C.S_OK then return nil; end
    local texture = d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', ptr[0]));
    local result, desc = texture:GetLevelDesc(0);
    if result ~= 0 then return nil; end
    return { Texture = texture, Width = desc.Width, Height = desc.Height };
end

-- key: 'file:<relative path>' or 'item:<id>'
local function GetTexture(key)
    local cached = textureCache[key];
    if cached ~= nil then
        return cached or nil;
    end
    local tx = nil;
    local kind, value = key:match('^(%a+):(.+)$');
    if kind == 'file' then
        tx = LoadTextureFromFile(ResourcePath(value));
    elseif kind == 'item' then
        tx = LoadItemTexture(tonumber(value));
    end
    textureCache[key] = tx or false;
    return tx;
end

local function ClearTextures()
    textureCache = {};
end

-- ============================================
-- Resource lookups (name -> icon key)
-- ============================================

local spellLookup   = nil;   -- lowercase name -> { index, name }
local spellSquash   = nil;   -- squashed name  -> same record
local abilityLookup = nil;   -- lowercase name -> { id, timerId, name }
local abilitySquash = nil;   -- squashed name  -> same record
local itemLookup    = nil;   -- lowercase name -> item id

-- 'Protect II' -> 'protectii': letters and digits only, lowercase.
local function Squash(name)
    return (name:lower():gsub('[^%w]', ''));
end

local function BuildSpellLookup()
    if spellLookup then return; end
    spellLookup = {};
    spellSquash = {};
    local resMgr = AshitaCore:GetResourceManager();
    for id = 0, 1024 do
        local spell = resMgr:GetSpellById(id);
        if spell and spell.Name and spell.Name[1] and spell.Name[1] ~= '' then
            local proper = spell.Name[1];
            local name = proper:lower();
            if not spellLookup[name] then
                local rec = { index = spell.Index or id, name = proper };
                spellLookup[name] = rec;
                local sq = Squash(proper);
                if not spellSquash[sq] then spellSquash[sq] = rec; end
            end
        end
    end
end

local function BuildAbilityLookup()
    if abilityLookup then return; end
    abilityLookup = {};
    abilitySquash = {};
    local resMgr = AshitaCore:GetResourceManager();
    for id = 0, 2048 do
        local ability = resMgr:GetAbilityById(id);
        if ability and ability.Name and ability.Name[1] and ability.Name[1] ~= '' then
            local proper = ability.Name[1];
            local name = proper:lower();
            if not abilityLookup[name] then
                local rec = { id = ability.Id or id, timerId = ability.RecastTimerId or 0, name = proper };
                abilityLookup[name] = rec;
                local sq = Squash(proper);
                if not abilitySquash[sq] then abilitySquash[sq] = rec; end
            end
        end
    end
end

-- Shorthand support: 'protect2' / 'protect 2' -> 'Protect II', 'utsusemi1' -> 'Utsusemi: Ichi'.
local ROMAN    = { 'i', 'ii', 'iii', 'iv', 'v', 'vi' };
local NINJUTSU = { 'ichi', 'ni', 'san' };

-- Candidate spellings to try, most literal first.
local function NameCandidates(name)
    local lowered = name:lower();
    local list = { lowered };
    local base, digits = lowered:match('^(.-)%s*(%d+)$');
    if base and base ~= '' then
        local n = tonumber(digits);
        if ROMAN[n] then
            table.insert(list, base .. ' ' .. ROMAN[n]);
        end
        if NINJUTSU[n] then
            table.insert(list, base .. ': ' .. NINJUTSU[n]);
            table.insert(list, base .. ' ' .. NINJUTSU[n]);
        end
    end
    return list;
end

local function FindRecord(lookup, squash, name)
    if not name then return nil; end
    for _, candidate in ipairs(NameCandidates(name)) do
        local rec = lookup[candidate] or squash[Squash(candidate)];
        if rec then return rec; end
    end
    return nil;
end

local function FindSpell(name)
    BuildSpellLookup();
    return FindRecord(spellLookup, spellSquash, name);
end

local function FindAbility(name)
    BuildAbilityLookup();
    return FindRecord(abilityLookup, abilitySquash, name);
end

local function BuildItemLookup()
    if itemLookup then return; end
    itemLookup = {};
    local resMgr = AshitaCore:GetResourceManager();
    for id = 1, 65535 do
        local item = resMgr:GetItemById(id);
        if item and item.Name and item.Name[1] and item.Name[1] ~= '' then
            local name = item.Name[1]:lower();
            if not itemLookup[name] then
                itemLookup[name] = id;
            end
        end
    end
end

local ICON_COMMAND = 'file:misc\\command.png';
local ICON_WS      = 'file:weaponskills\\default.png';
local ICON_2HR     = 'file:abilities\\1hr.png';

-- Build a texture key from an override record.
local function IconKeyFromOverride(override)
    if not override or not override.kind or override.value == nil then return nil; end
    if override.kind == 'spell' then
        return string.format('file:spells\\%u.png', tonumber(override.value) or 0);
    elseif override.kind == 'ability' then
        return string.format('file:abilities\\%s.png', tostring(override.value));
    elseif override.kind == 'item' then
        return string.format('item:%u', tonumber(override.value) or 0);
    elseif override.kind == 'misc' then
        return string.format('file:misc\\%s', tostring(override.value));
    end
    return nil;
end

-- Resolve an icon cache key for a parsed action, or nil for no icon.
local function ResolveIconKey(action)
    if not action or not action.name then
        return ICON_COMMAND;
    end
    local name = action.name:lower();

    if action.kind == 'ma' then
        local rec = FindSpell(name);
        if rec then
            return string.format('file:spells\\%u.png', rec.index);
        end
        return ICON_COMMAND;
    end

    if action.kind == 'ja' or action.kind == 'pet' then
        local ab = FindAbility(name);
        if ab then
            if ab.timerId == 0 or ab.timerId == 254 then
                return ICON_2HR;
            end
            if ab.id >= 0x200 then
                return string.format('file:abilities\\%u.png', ab.id - 0x200);
            end
            return ICON_WS;
        end
        return ICON_COMMAND;
    end

    if action.kind == 'ws' then
        return ICON_WS;
    end

    if action.kind == 'item' or action.kind == 'equip' then
        BuildItemLookup();
        local id = itemLookup[name];
        if id then
            return string.format('item:%u', id);
        end
        return ICON_COMMAND;
    end

    return ICON_COMMAND;
end

-- ============================================
-- Recast timers
-- ============================================

-- Resolve what to read for a bind's cooldown: { kind = 'spell', index } or
-- { kind = 'ability', timerId }. Returns false when the action has no recast.
local function ResolveRecastRef(action)
    if not action or not action.name then return false; end
    local name = action.name:lower();

    if action.kind == 'ma' then
        local rec = FindSpell(name);
        if rec then
            return { kind = 'spell', index = rec.index };
        end
    elseif action.kind == 'ja' or action.kind == 'pet' then
        local ab = FindAbility(name);
        if ab and ab.id >= 0x200 then
            return { kind = 'ability', timerId = ab.timerId or 0 };
        end
    end
    return false;
end

-- Raw timer values are in 1/60th of a second.
local function ReadRecastRaw(ref)
    local recast = AshitaCore:GetMemoryManager():GetRecast();
    if not recast then return 0; end

    if ref.kind == 'spell' then
        return recast:GetSpellTimer(ref.index) or 0;
    end

    if ref.kind == 'ability' then
        -- Timer id 0 is the two-hour, which always lives in slot 0.
        if ref.timerId == 0 or ref.timerId == 254 then
            return recast:GetAbilityTimer(0) or 0;
        end
        for slot = 1, 31 do
            if recast:GetAbilityTimerId(slot) == ref.timerId then
                return recast:GetAbilityTimer(slot) or 0;
            end
        end
    end
    return 0;
end

local RECAST_TTL = 0.1;   -- seconds between memory reads per slot

-- Remaining seconds for a bind, cached briefly to keep per-frame cost low.
local function GetRecastRemaining(b)
    if b.recastRef == nil then
        b.recastRef = ResolveRecastRef(b.action);
    end
    if not b.recastRef then return 0; end

    local now = os.clock();
    if b.recastExpiry and now < b.recastExpiry then
        return b.recastValue or 0;
    end
    b.recastValue = ReadRecastRaw(b.recastRef) / 60;
    b.recastExpiry = now + RECAST_TTL;
    return b.recastValue;
end

local function FormatRecast(seconds)
    if seconds <= 0 then return nil; end
    if seconds >= 3600 then
        return string.format('%dh%02d', math.floor(seconds / 3600), math.floor((seconds % 3600) / 60));
    elseif seconds >= 60 then
        return string.format('%d:%02d', math.floor(seconds / 60), math.floor(seconds % 60));
    else
        return string.format('%d', math.ceil(seconds));
    end
end

-- ============================================
-- Parsing
-- ============================================

local MODIFIER_NAMES = {
    ['!'] = 'A',   -- Alt
    ['^'] = 'C',   -- Ctrl
    ['+'] = 'S',   -- Shift
    ['@'] = 'W',   -- Win
    ['#'] = 'M',   -- Apps/menu
};

local MODIFIER_LONG = {
    ['!'] = 'Alt', ['^'] = 'Ctrl', ['+'] = 'Shift', ['@'] = 'Win', ['#'] = 'Apps',
};

-- Short label for the slot: '^1' -> 'C1', '!x' -> 'AX', 'F11' -> 'F11'
local function FormatKeyShort(rawKey)
    local prefix = '';
    local working = rawKey;
    while #working > 1 and MODIFIER_NAMES[working:sub(1, 1)] do
        prefix = prefix .. MODIFIER_NAMES[working:sub(1, 1)];
        working = working:sub(2);
    end
    if #working == 1 then working = working:upper(); end
    return prefix .. working;
end

-- Long label for tooltips: '^1' -> 'Ctrl+1'
local function FormatKeyLong(rawKey)
    local parts = {};
    local working = rawKey;
    while #working > 1 and MODIFIER_LONG[working:sub(1, 1)] do
        table.insert(parts, MODIFIER_LONG[working:sub(1, 1)]);
        working = working:sub(2);
    end
    if #working == 1 then working = working:upper(); end
    table.insert(parts, working);
    return table.concat(parts, '+');
end

local function CleanTarget(target)
    if not target then return nil; end
    local cleaned = target:gsub('[<>]', '');
    if cleaned == '' then return nil; end
    return cleaned;
end

-- Turn a bound command into { kind, name, target, raw } for display.
local function ParseAction(command)
    local action = { raw = command };
    local cmdWord, rest = command:match('^/(%S+)%s*(.*)$');
    if not cmdWord then
        action.kind = 'raw';
        return action;
    end
    cmdWord = cmdWord:lower();

    local function nameAndTarget(str)
        local name, target = str:match('^"([^"]+)"%s*(%S*)');
        if not name then
            name, target = str:match('^(%S+)%s*(%S*)');
        end
        return name, CleanTarget(target);
    end

    if cmdWord == 'ma' or cmdWord == 'magic' then
        action.kind = 'ma';
        action.name, action.target = nameAndTarget(rest);
    elseif cmdWord == 'ja' or cmdWord == 'jobability' then
        action.kind = 'ja';
        action.name, action.target = nameAndTarget(rest);
    elseif cmdWord == 'ws' or cmdWord == 'weaponskill' then
        action.kind = 'ws';
        action.name, action.target = nameAndTarget(rest);
    elseif cmdWord == 'pet' then
        action.kind = 'pet';
        action.name, action.target = nameAndTarget(rest);
    elseif cmdWord == 'item' then
        action.kind = 'item';
        action.name, action.target = nameAndTarget(rest);
    elseif cmdWord == 'equip' then
        action.kind = 'equip';
        local slot, itemStr = rest:match('^(%S+)%s+(.*)$');
        if slot then
            action.name = itemStr:match('^"([^"]+)"') or itemStr;
            action.target = slot;
        end
    end

    if not action.name then
        action.kind = 'raw';
    end
    return action;
end

local function IsIgnored(command)
    local lowered = command:lower();
    for _, prefix in ipairs(bv.settings.ignore or {}) do
        if lowered:sub(1, #prefix) == prefix:lower() then
            return true;
        end
    end
    return false;
end

local function AddBind(rawKey, command)
    local key = rawKey:lower();
    local action = ParseAction(command);
    local entry = {
        key       = rawKey,
        shortKey  = FormatKeyShort(rawKey),
        longKey   = FormatKeyLong(rawKey),
        command   = command,
        action    = action,
        hidden    = IsIgnored(command),
        iconKey   = nil,   -- resolved lazily on first draw (needs resources ready)
    };
    local existing = bv.index[key];
    if existing then
        bv.binds[existing] = entry;
    else
        bv.binds:append(entry);
        bv.index[key] = #bv.binds;
    end
end

local function RebuildIndex()
    bv.index = {};
    for i, entry in ipairs(bv.binds) do
        bv.index[entry.key:lower()] = i;
    end
end

local function RemoveBind(rawKey)
    local idx = bv.index[rawKey:lower()];
    if not idx then return; end
    table.remove(bv.binds, idx);
    RebuildIndex();
end

local function ClearBinds()
    bv.binds = T{};
    bv.index = {};
end

-- Ashita bind syntax: /bind [flags] <key> <command>
local function HandleBindCommand(commandText)
    local rest = commandText:match('^/bind%s+(.+)$');
    if not rest then return; end

    local token, remainder = rest:match('^(%S+)%s*(.*)$');
    while token and token:sub(1, 1) == '-' do
        token, remainder = remainder:match('^(%S+)%s*(.*)$');
    end
    if not token or not remainder or remainder == '' then
        return;
    end
    local unquoted = remainder:match('^"(.*)"$');
    if unquoted then remainder = unquoted; end

    AddBind(token, remainder);
end

local function HandleUnbindCommand(commandText)
    local key = commandText:match('^/unbind%s+(%S+)');
    if not key then return; end
    if key:lower() == 'all' then
        ClearBinds();
    else
        RemoveBind(key);
    end
end

-- ============================================
-- Messages
-- ============================================

local function Message(text)
    print(chat.header(addon.name):append(chat.message(text)));
end

local function ErrorMessage(text)
    print(chat.header(addon.name):append(chat.error(text)));
end

-- ============================================
-- Profiles
-- ============================================
-- A profile is a snapshot of the visible binds (key + command) saved as a Lua
-- file under config/addons/bindview/profiles/. Loading one unbinds the keys
-- bindview currently tracks and re-issues /bind for each saved entry. Those
-- commands go through the same pipeline the watcher listens to, so the overlay
-- updates itself.

local function ProfileDir()
    return string.format('%sconfig\\addons\\%s\\profiles\\', AshitaCore:GetInstallPath(), addon.name);
end

local function SanitizeProfileName(name)
    return (tostring(name or ''):gsub('[^%w%-_]', ''));
end

local function ProfilePath(name)
    return ProfileDir() .. SanitizeProfileName(name) .. '.lua';
end

local function ListProfiles()
    local names = T{};
    local dir = ProfileDir();
    if not ashita.fs.exists(dir) then return names; end
    local files = ashita.fs.get_directory(dir, '.*\\.lua') or {};
    for _, file in ipairs(files) do
        names:append((file:gsub('%.lua$', '')));
    end
    table.sort(names);
    return names;
end

local function SaveProfile(name)
    name = SanitizeProfileName(name);
    if name == '' then return false, 'Profile name must contain letters or numbers.'; end

    local dir = ProfileDir();
    if not ashita.fs.exists(dir) then
        ashita.fs.create_directory(dir);
    end

    local file = io.open(ProfilePath(name), 'w');
    if not file then return false, 'Could not write profile file.'; end

    local count = 0;
    file:write('-- bindview profile. Each entry is issued as: /bind <key> <command>\n');
    file:write('return {\n');
    for _, b in ipairs(bv.binds) do
        if not b.hidden then
            file:write(string.format('    { key = %q, command = %q },\n', b.key, b.command));
            count = count + 1;
        end
    end
    file:write('}\n');
    file:close();
    return true, count;
end

local function ReadProfile(name)
    local path = ProfilePath(name);
    if not ashita.fs.exists(path) then return nil, 'No profile named "' .. name .. '".'; end
    local chunk, err = loadfile(path);
    if not chunk then return nil, 'Could not read profile: ' .. tostring(err); end
    local ok, data = pcall(chunk);
    if not ok or type(data) ~= 'table' then return nil, 'Profile file is not valid.'; end
    return data;
end

local function LoadProfile(name)
    name = SanitizeProfileName(name);
    local data, err = ReadProfile(name);
    if not data then return false, err; end

    local cm = AshitaCore:GetChatManager();

    -- Release everything bindview currently tracks (never the hidden system binds).
    for _, b in ipairs(bv.binds) do
        if not b.hidden then
            cm:QueueCommand(1, '/unbind ' .. b.key);
        end
    end

    local count = 0;
    for _, entry in ipairs(data) do
        if type(entry) == 'table' and entry.key and entry.command then
            cm:QueueCommand(1, string.format('/bind %s %s', entry.key, entry.command));
            count = count + 1;
        end
    end

    bv.settings.currentProfile = name;
    SaveSettings();
    return true, count;
end

local function DeleteProfile(name)
    name = SanitizeProfileName(name);
    local path = ProfilePath(name);
    if not ashita.fs.exists(path) then return false, 'No profile named "' .. name .. '".'; end
    local ok = os.remove(path);
    if ok and bv.settings.currentProfile == name then
        bv.settings.currentProfile = '';
        SaveSettings();
    end
    return ok ~= nil;
end

-- Step through profiles alphabetically; direction is 1 or -1.
local function CycleProfile(direction)
    local names = ListProfiles();
    if #names == 0 then return false, 'No profiles saved yet.'; end
    local current = bv.settings.currentProfile or '';
    local index = 0;
    for i, n in ipairs(names) do
        if n == current then index = i; break; end
    end
    if index == 0 then
        index = (direction > 0) and 1 or #names;
    else
        index = ((index - 1 + direction) % #names) + 1;
    end
    return LoadProfile(names[index]);
end

-- ============================================
-- Commands
-- ============================================

local function PrintHelp()
    Message('Commands:');
    local cmds = T{
        { '/bindview',               'Toggle the overlay.' },
        { '/bindview config',        'Open the settings window.' },
        { '/bindview show | hide',   'Show or hide the overlay.' },
        { '/bindview lock | unlock', 'Lock or unlock the overlay position.' },
        { '/bindview list',          'Print the captured binds to chat.' },
        { '/bindview clear',         'Forget every captured bind.' },
        { '/bindview reset',         'Reset settings to defaults.' },
        { '/bindview save <name>',   'Save the current binds as a profile.' },
        { '/bindview load <name>',   'Unbind tracked keys and apply a saved profile.' },
        { '/bindview next | prev',   'Cycle to the next or previous profile.' },
        { '/bindview profiles',      'List saved profiles.' },
        { '/bindview delete <name>', 'Delete a saved profile.' },
    };
    cmds:ieach(function(v)
        print(chat.header(addon.name):append(chat.message(v[1]):append(' - ')):append(chat.color1(6, v[2])));
    end);
end

ashita.events.register('command', 'command_cb', function(e)
    local text = e.command:match('^%s*(.-)%s*$');
    local lowered = text:lower();

    -- Passive watchers: never block these.
    if lowered:sub(1, 6) == '/bind ' then
        HandleBindCommand(text);
        return;
    end
    if lowered:sub(1, 8) == '/unbind ' then
        HandleUnbindCommand(text);
        return;
    end

    local args = e.command:args();
    if #args == 0 or args[1]:lower() ~= '/bindview' then
        return;
    end
    e.blocked = true;

    local s = bv.settings;
    if #args == 1 or args[2]:any('toggle') then
        s.visible = not s.visible;
    elseif args[2]:any('config', 'cfg', 'settings') then
        bv.configOpen = not bv.configOpen;
        SyncConfigFromSettings();
    elseif args[2]:any('show') then
        s.visible = true;
    elseif args[2]:any('hide') then
        s.visible = false;
    elseif args[2]:any('lock') then
        s.locked = true;
        Message('Position locked.');
    elseif args[2]:any('unlock') then
        s.locked = false;
        Message('Position unlocked.');
    elseif args[2]:any('list') then
        if #bv.binds == 0 then
            Message('No binds captured yet.');
        end
        for _, b in ipairs(bv.binds) do
            if not b.hidden then
                Message(('%s  %s'):fmt(b.longKey, b.command));
            end
        end
    elseif args[2]:any('clear') then
        ClearBinds();
        Message('Cleared.');
    elseif args[2]:any('save') and #args >= 3 then
        local ok, result = SaveProfile(args[3]);
        if ok then
            Message(('Saved profile "%s" (%d binds).'):fmt(SanitizeProfileName(args[3]), result));
        else
            ErrorMessage(result);
        end
    elseif args[2]:any('load') and #args >= 3 then
        local ok, result = LoadProfile(args[3]);
        if ok then
            Message(('Loaded profile "%s" (%d binds).'):fmt(SanitizeProfileName(args[3]), result));
        else
            ErrorMessage(result);
        end
    elseif args[2]:any('next', 'prev', 'previous') then
        local ok, result = CycleProfile(args[2]:any('next') and 1 or -1);
        if ok then
            Message(('Profile: %s'):fmt(bv.settings.currentProfile));
        else
            ErrorMessage(result);
        end
    elseif args[2]:any('profiles') then
        local names = ListProfiles();
        if #names == 0 then
            Message('No profiles saved yet. Use /bindview save <name>.');
        end
        for _, n in ipairs(names) do
            local marker = (n == bv.settings.currentProfile) and '  (active)' or '';
            Message(n .. marker);
        end
    elseif args[2]:any('delete') and #args >= 3 then
        local ok, err = DeleteProfile(args[3]);
        if ok then
            Message(('Deleted profile "%s".'):fmt(SanitizeProfileName(args[3])));
        else
            ErrorMessage(err or 'Could not delete profile.');
        end
    elseif args[2]:any('reset') then
        settings.reset();
        Message('Settings reset.');
    else
        PrintHelp();
        return;
    end
    SyncConfigFromSettings();
    SaveSettings();
end);

-- ============================================
-- Rendering helpers
-- ============================================

local COL_SLOT_BG   = 0x99000000;   -- ABGR: mostly opaque black
local COL_SLOT_EDGE = 0x66FFFFFF;
local COL_KEY_TEXT  = 0xFFFFFFFF;
local COL_KEY_SHADE = 0xFF000000;
local COL_NAME_TEXT = 0xFFDDDDDD;
local COL_RECAST_BG = 0xB0000000;   -- dark veil over an icon on cooldown
local COL_RECAST_TX = 0xFF66E0FF;   -- ABGR: warm yellow

-- Font scaling differs between Ashita builds.
local function ApplyFontScale(scale)
    if scale == 1.0 then return false; end
    if imgui.SetWindowFontScale then
        imgui.SetWindowFontScale(scale);
        return true;
    elseif imgui.PushFont and imgui.GetFont and imgui.GetFontSize then
        imgui.PushFont(imgui.GetFont(), imgui.GetFontSize() * scale);
        return true;
    end
    return false;
end

local function UnapplyFontScale(applied)
    if not applied then return; end
    if imgui.SetWindowFontScale then
        imgui.SetWindowFontScale(1.0);
    elseif imgui.PopFont then
        imgui.PopFont();
    end
end

local function TextureId(tx)
    return tonumber(ffi.cast('uint32_t', tx.Texture));
end

-- Draw text with a full 1px dark outline (8 directions) using the window draw list.
local function OutlinedText(drawList, x, y, text, color)
    for dx = -1, 1 do
        for dy = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
                drawList:AddText({ x + dx, y + dy }, COL_KEY_SHADE, text);
            end
        end
    end
    drawList:AddText({ x, y }, color or COL_KEY_TEXT, text);
end

local COL_BADGE_BG = 0xD0000000;

-- Key label with an optional solid badge behind it so it reads over any icon.
local function DrawKeyLabel(drawList, s, x, y, text)
    local w = imgui.CalcTextSize(text);
    local h = imgui.GetTextLineHeight();
    local color = imgui.GetColorU32(s.keyColor or defaultSettings.keyColor);
    if s.keyBadge ~= false then
        drawList:AddRectFilled({ x, y }, { x + w + 5, y + h + 1 }, COL_BADGE_BG, 3.0);
    end
    OutlinedText(drawList, x + 2, y, text, color);
end

local function ActionTooltip(b)
    imgui.BeginTooltip();
    imgui.Text(b.longKey);
    imgui.Separator();
    local a = b.action;
    if a.kind ~= 'raw' and a.name then
        local shown = a.displayName or a.name;
        local line = shown;
        if a.kind == 'equip' and a.target then
            line = ('%s (%s)'):fmt(shown, a.target);
        elseif a.target then
            line = ('%s <%s>'):fmt(shown, a.target);
        end
        imgui.Text(line);
    end
    imgui.TextDisabled(b.command);
    imgui.EndTooltip();
end

local function DrawSlot(b, s, drawList, x, y, size)
    -- Slot background
    drawList:AddRectFilled({ x, y }, { x + size, y + size }, COL_SLOT_BG, 3.0);

    -- Icon: manual override wins, otherwise resolve from the action name
    if b.iconKey == nil then
        local override = bv.settings.iconOverrides and bv.settings.iconOverrides[b.key:lower()];
        b.iconKey = IconKeyFromOverride(override) or ResolveIconKey(b.action) or false;

        -- Canonical game name for labels/tooltips, so 'protect2' shows as 'Protect II'
        local a = b.action;
        if a.kind == 'ma' then
            local rec = FindSpell(a.name);
            if rec then a.displayName = rec.name; end
        elseif a.kind == 'ja' or a.kind == 'pet' then
            local rec = FindAbility(a.name);
            if rec then a.displayName = rec.name; end
        end
    end
    local tx = b.iconKey and GetTexture(b.iconKey) or nil;
    imgui.SetCursorScreenPos({ x, y });
    if tx then
        imgui.Image(TextureId(tx), { size, size });
    else
        imgui.Dummy({ size, size });
    end
    local hovered = imgui.IsItemHovered();

    drawList:AddRect({ x, y }, { x + size, y + size }, COL_SLOT_EDGE, 3.0);

    -- Recast: veil the icon and draw the remaining time centered
    if s.showRecast ~= false then
        local remaining = GetRecastRemaining(b);
        local text = FormatRecast(remaining);
        if text then
            drawList:AddRectFilled({ x, y }, { x + size, y + size }, COL_RECAST_BG, 3.0);
            local w = imgui.CalcTextSize(text);
            local h = imgui.GetTextLineHeight();
            OutlinedText(drawList, x + (size - w) / 2, y + (size - h) / 2, text, COL_RECAST_TX);
        end
    end

    -- Key label, top-left
    DrawKeyLabel(drawList, s, x + 1, y + 1, b.shortKey);

    -- Target hint, bottom-right (skip <me>)
    if s.showTarget and b.action.target and b.action.target ~= 'me' and b.action.kind ~= 'equip' then
        local hint = b.action.target;
        local w = imgui.CalcTextSize(hint);
        OutlinedText(drawList, x + size - w - 2, y + size - imgui.GetTextLineHeight() - 1, hint);
    end

    if hovered then
        ActionTooltip(b);
    end
end

-- ============================================
-- Keyboard layout
-- ============================================

-- Physical positions in key units for a US QWERTY board. x is measured from
-- the left edge of the backtick key; each row's stagger matches a real board.
local KEYBOARD_ROWS = T{
    { y = 0, keys = { { 'f1', 2 }, { 'f2', 3 }, { 'f3', 4 }, { 'f4', 5 },
                      { 'f5', 6.5 }, { 'f6', 7.5 }, { 'f7', 8.5 }, { 'f8', 9.5 },
                      { 'f9', 11 }, { 'f10', 12 }, { 'f11', 13 }, { 'f12', 14 } } },
    { y = 1, keys = { { '`', 0 }, { '1', 1 }, { '2', 2 }, { '3', 3 }, { '4', 4 }, { '5', 5 }, { '6', 6 },
                      { '7', 7 }, { '8', 8 }, { '9', 9 }, { '0', 10 }, { '-', 11 }, { '=', 12 } } },
    { y = 2, keys = { { 'q', 1.5 }, { 'w', 2.5 }, { 'e', 3.5 }, { 'r', 4.5 }, { 't', 5.5 }, { 'y', 6.5 },
                      { 'u', 7.5 }, { 'i', 8.5 }, { 'o', 9.5 }, { 'p', 10.5 }, { '[', 11.5 }, { ']', 12.5 }, { '\\', 13.5 } } },
    { y = 3, keys = { { 'a', 1.75 }, { 's', 2.75 }, { 'd', 3.75 }, { 'f', 4.75 }, { 'g', 5.75 }, { 'h', 6.75 },
                      { 'j', 7.75 }, { 'k', 8.75 }, { 'l', 9.75 }, { ';', 10.75 }, { "'", 11.75 } } },
    { y = 4, keys = { { 'z', 2.25 }, { 'x', 3.25 }, { 'c', 4.25 }, { 'v', 5.25 }, { 'b', 6.25 }, { 'n', 7.25 },
                      { 'm', 8.25 }, { ',', 9.25 }, { '.', 10.25 }, { '/', 11.25 } } },
};

-- keyname -> { x, row }
local KEY_POSITIONS = {};
for rowIndex, row in ipairs(KEYBOARD_ROWS) do
    for _, k in ipairs(row.keys) do
        KEY_POSITIONS[k[1]] = { x = k[2], row = rowIndex };
    end
end

-- Modifier layers in display order. Any other combination is appended after.
local LAYER_ORDER = T{ '', '+', '^', '!', '^+', '!+', '^!' };
local LAYER_LABELS = { [''] = '', ['+'] = 'Shift', ['^'] = 'Ctrl', ['!'] = 'Alt',
                       ['^+'] = 'Ctrl+Shift', ['!+'] = 'Alt+Shift', ['^!'] = 'Ctrl+Alt' };

-- Split '^!x' into a canonical modifier prefix ('^!') and the bare key ('x').
local function SplitBindKey(rawKey)
    local mods = {};
    local working = rawKey;
    while #working > 1 and MODIFIER_NAMES[working:sub(1, 1)] do
        mods[working:sub(1, 1)] = true;
        working = working:sub(2);
    end
    local prefix = '';
    for _, m in ipairs({ '^', '!', '+', '@', '#' }) do
        if mods[m] then prefix = prefix .. m; end
    end
    return prefix, working:lower();
end

local function LayerLabel(prefix)
    if LAYER_LABELS[prefix] then return LAYER_LABELS[prefix]; end
    local parts = {};
    for i = 1, #prefix do
        table.insert(parts, MODIFIER_LONG[prefix:sub(i, i)] or prefix:sub(i, i));
    end
    return table.concat(parts, '+');
end

local COL_EMPTY_BG   = 0x30000000;
local COL_EMPTY_EDGE = 0x22FFFFFF;
local COL_EMPTY_TEXT = 0x55FFFFFF;
local COL_LAYER_TEXT = 0xFFFFD088;

local function DrawEmptyKey(drawList, x, y, size, label)
    drawList:AddRectFilled({ x, y }, { x + size, y + size }, COL_EMPTY_BG, 3.0);
    drawList:AddRect({ x, y }, { x + size, y + size }, COL_EMPTY_EDGE, 3.0);
    drawList:AddText({ x + 2, y + 1 }, COL_EMPTY_TEXT, label);
end

-- Lay the visible binds out as stacked keyboards, one per modifier layer.
-- Returns the total width and height used.
local function DrawKeyboardLayout(visible, s, drawList, originX, originY)
    local size = s.iconSize;
    local pad = s.padding;
    local unit = size + pad;
    local lineH = imgui.GetTextLineHeight();
    local nameH = s.showNames and (lineH + 1) or 0;
    local rowH = unit + nameH;

    -- Bucket binds by layer; anything not on the map goes to 'other'.
    local layers = {};
    local other = T{};
    for _, b in ipairs(visible) do
        local prefix, keyName = SplitBindKey(b.key);
        local pos = KEY_POSITIONS[keyName];
        if pos then
            layers[prefix] = layers[prefix] or { binds = {}, rows = {}, minX = math.huge, maxX = -math.huge };
            local layer = layers[prefix];
            layer.binds[keyName] = b;
            layer.rows[pos.row] = true;
            if pos.x < layer.minX then layer.minX = pos.x; end
            if pos.x > layer.maxX then layer.maxX = pos.x; end
        else
            other:append(b);
        end
    end

    -- Order layers: known order first, then any leftovers alphabetically.
    local ordered = T{};
    for _, prefix in ipairs(LAYER_ORDER) do
        if layers[prefix] then ordered:append(prefix); end
    end
    local leftovers = T{};
    for prefix, _ in pairs(layers) do
        if not LAYER_ORDER:contains(prefix) then leftovers:append(prefix); end
    end
    table.sort(leftovers);
    for _, prefix in ipairs(leftovers) do ordered:append(prefix); end

    local cursorY = originY;
    local totalW = 0;

    for _, prefix in ipairs(ordered) do
        local layer = layers[prefix];
        local label = LayerLabel(prefix);

        if label ~= '' then
            drawList:AddText({ originX, cursorY }, COL_LAYER_TEXT, label);
            cursorY = cursorY + lineH + 1;
        end

        -- Crop to the horizontal span of bound keys in this layer.
        local spanW = (layer.maxX - layer.minX + 1) * unit - pad;
        if spanW > totalW then totalW = spanW; end

        for rowIndex, row in ipairs(KEYBOARD_ROWS) do
            if layer.rows[rowIndex] then
                for _, k in ipairs(row.keys) do
                    local keyName, kx = k[1], k[2];
                    if kx >= layer.minX and kx <= layer.maxX then
                        local sx = originX + (kx - layer.minX) * unit;
                        local b = layer.binds[keyName];
                        if b then
                            DrawSlot(b, s, drawList, sx, cursorY, size);
                            if s.showNames then
                                local nameLabel = b.action.displayName or b.action.name or b.action.raw or '';
                                while #nameLabel > 1 and imgui.CalcTextSize(nameLabel) > size do
                                    nameLabel = nameLabel:sub(1, #nameLabel - 1);
                                end
                                local w = imgui.CalcTextSize(nameLabel);
                                drawList:AddText({ sx + (size - w) / 2, cursorY + size + 1 }, COL_NAME_TEXT, nameLabel);
                            end
                        elseif s.showEmptyKeys ~= false then
                            DrawEmptyKey(drawList, sx, cursorY, size, keyName:upper());
                        end
                    end
                end
                cursorY = cursorY + rowH;
            end
        end
        cursorY = cursorY + pad;   -- gap between layers
    end

    -- Keys that have no place on the map (numpad, insert, ...) go in a plain row.
    if #other > 0 then
        local cols = math.max(1, s.columns);
        local rows = math.ceil(#other / cols);
        for i, b in ipairs(other) do
            local col = (i - 1) % cols;
            local row = math.floor((i - 1) / cols);
            DrawSlot(b, s, drawList, originX + col * unit, cursorY + row * rowH, size);
        end
        local w = cols * unit - pad;
        if w > totalW then totalW = w; end
        cursorY = cursorY + rows * rowH;
    end

    return totalW, cursorY - originY - pad;
end

-- Plain wrapped grid in bind order.
local function DrawGridLayout(visible, s, drawList, originX, originY)
    local size = s.iconSize;
    local pad = s.padding;
    local cols = math.max(1, s.columns);
    local lineH = imgui.GetTextLineHeight();
    local rowH = size + pad + (s.showNames and (lineH + 1) or 0);
    local rows = math.ceil(#visible / cols);

    for i, b in ipairs(visible) do
        local col = (i - 1) % cols;
        local row = math.floor((i - 1) / cols);
        local sx = originX + col * (size + pad);
        local sy = originY + row * rowH;
        DrawSlot(b, s, drawList, sx, sy, size);

        if s.showNames then
            local label = b.action.displayName or b.action.name or b.action.raw or '';
            while #label > 1 and imgui.CalcTextSize(label) > size do
                label = label:sub(1, #label - 1);
            end
            local w = imgui.CalcTextSize(label);
            drawList:AddText({ sx + (size - w) / 2, sy + size + 1 }, COL_NAME_TEXT, label);
        end
    end

    return cols * (size + pad) - pad, rows * rowH - pad;
end

-- ============================================
-- Overlay window
-- ============================================

local function DrawOverlay()
    local s = bv.settings;
    if not s.visible then return; end

    local flags = bit.bor(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoSavedSettings
    );
    if s.locked then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove);
    end

    if not bv.positionApplied then
        imgui.SetNextWindowPos({ s.position_x, s.position_y }, ImGuiCond_Always);
        bv.positionApplied = true;
    end
    imgui.SetNextWindowBgAlpha(s.alpha);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { s.padding, s.padding });

    if imgui.Begin('bindview##overlay', true, flags) then
        local x, y = imgui.GetWindowPos();
        if x and y and (x ~= s.position_x or y ~= s.position_y) then
            s.position_x = x;
            s.position_y = y;
        end

        local visible = T{};
        for _, b in ipairs(bv.binds) do
            if not b.hidden then visible:append(b); end
        end

        local profileName = bv.settings.currentProfile or '';
        if s.showProfileName ~= false and profileName ~= '' then
            imgui.TextColored({ 1.0, 0.82, 0.53, 1.0 }, profileName);
        end

        if #visible == 0 then
            imgui.TextDisabled('No binds captured');
        else
            local scaled = ApplyFontScale(s.keyScale);
            local drawList = imgui.GetWindowDrawList();
            local originX, originY = imgui.GetCursorScreenPos();

            local usedW, usedH;
            if s.layout == 'grid' then
                usedW, usedH = DrawGridLayout(visible, s, drawList, originX, originY);
            else
                usedW, usedH = DrawKeyboardLayout(visible, s, drawList, originX, originY);
            end

            -- Reserve the drawn area so the window auto-sizes around it
            imgui.SetCursorScreenPos({ originX, originY });
            imgui.Dummy({ math.max(1, usedW), math.max(1, usedH) });

            UnapplyFontScale(scaled);
        end
    end
    imgui.End();
    imgui.PopStyleVar();
end

-- ============================================
-- Icon picker (config window)
-- ============================================

local ICON_SOURCES = T{ 'Auto', 'Spell', 'Ability', 'Item', 'Generic' };

local picker = {
    bindIndex   = 1,          -- index into bv.binds
    sourceIndex = 1,          -- index into ICON_SOURCES
    filter      = { '' },
    lists       = {},         -- source -> sorted { name, value } (built lazily)
};

-- Sorted name lists for each source, built once from the resource manager.
local function GetPickerList(source)
    if picker.lists[source] then return picker.lists[source]; end
    local list = T{};

    if source == 'Spell' then
        BuildSpellLookup();
        for name, rec in pairs(spellLookup) do
            list:append({ name = name, value = rec.index });
        end
    elseif source == 'Ability' then
        BuildAbilityLookup();
        for name, ab in pairs(abilityLookup) do
            local value;
            if ab.timerId == 0 or ab.timerId == 254 then
                value = '1hr';
            elseif ab.id >= 0x200 then
                value = tostring(ab.id - 0x200);
            end
            if value then
                list:append({ name = name, value = value });
            end
        end
    elseif source == 'Item' then
        BuildItemLookup();
        for name, id in pairs(itemLookup) do
            list:append({ name = name, value = id });
        end
    elseif source == 'Generic' then
        local dir = ResourcePath('misc');
        local files = ashita.fs.get_directory(dir, '.*\\.png');
        if files then
            for _, file in ipairs(files) do
                list:append({ name = file:gsub('%.png$', ''), value = file });
            end
        end
    end

    table.sort(list, function(a, b) return a.name < b.name; end);
    picker.lists[source] = list;
    return list;
end

local function TitleCase(name)
    return (name:gsub("(%a)([%w']*)", function(first, rest) return first:upper() .. rest; end));
end

local function SetOverride(b, kind, value)
    if not bv.settings.iconOverrides then bv.settings.iconOverrides = T{}; end
    bv.settings.iconOverrides[b.key:lower()] = { kind = kind, value = value };
    b.iconKey = nil;
    SaveSettings();
end

local function ClearOverride(b)
    if bv.settings.iconOverrides then
        bv.settings.iconOverrides[b.key:lower()] = nil;
    end
    b.iconKey = nil;
    SaveSettings();
end

local function DrawIconPreview(iconKey, size)
    local tx = iconKey and GetTexture(iconKey) or nil;
    if tx then
        imgui.Image(TextureId(tx), { size, size });
    else
        imgui.Dummy({ size, size });
    end
end

local function DrawIconPicker()
    imgui.TextColored({ 1.0, 0.85, 0.4, 1.0 }, 'Icons');
    if #bv.binds == 0 then
        imgui.TextDisabled('No binds captured yet.');
        return;
    end

    -- Bind selector
    if picker.bindIndex > #bv.binds then picker.bindIndex = 1; end
    local current = bv.binds[picker.bindIndex];
    local function BindLabel(b)
        return ('%s  %s'):fmt(b.longKey, b.action.displayName or b.action.name or b.action.raw or '');
    end
    if imgui.BeginCombo('Bind', BindLabel(current)) then
        for i, b in ipairs(bv.binds) do
            if imgui.Selectable(BindLabel(b) .. '##bind' .. i, i == picker.bindIndex) then
                picker.bindIndex = i;
            end
        end
        imgui.EndCombo();
    end
    current = bv.binds[picker.bindIndex];

    -- Current icon preview and override state
    local override = bv.settings.iconOverrides and bv.settings.iconOverrides[current.key:lower()];
    if current.iconKey == nil then
        current.iconKey = IconKeyFromOverride(override) or ResolveIconKey(current.action) or false;
    end
    DrawIconPreview(current.iconKey, 32);
    imgui.SameLine();
    imgui.BeginGroup();
    if override then
        imgui.Text(('Manual: %s'):fmt(override.kind));
        if imgui.Button('Use automatic icon') then
            ClearOverride(current);
        end
    else
        imgui.Text('Automatic');
        imgui.TextDisabled('Pick a source below to override.');
    end
    imgui.EndGroup();

    -- Source selector
    if imgui.BeginCombo('Source', ICON_SOURCES[picker.sourceIndex]) then
        for i, name in ipairs(ICON_SOURCES) do
            if imgui.Selectable(name .. '##src' .. i, i == picker.sourceIndex) then
                picker.sourceIndex = i;
            end
        end
        imgui.EndCombo();
    end

    local source = ICON_SOURCES[picker.sourceIndex];
    if source == 'Auto' then
        return;
    end

    -- Optional filter to narrow the list; the choice itself is a click.
    imgui.InputText('Filter', picker.filter, 64);
    local filter = picker.filter[1]:lower();
    if source == 'Item' and #filter < 2 then
        imgui.TextDisabled('Type at least two letters to list items.');
        return;
    end

    local list = GetPickerList(source);
    local kind = ({ Spell = 'spell', Ability = 'ability', Item = 'item', Generic = 'misc' })[source];

    imgui.BeginChild('##iconlist', { 0, 220 }, ImGuiChildFlags_Borders);
    local shown = 0;
    for i, entry in ipairs(list) do
        if filter == '' or entry.name:find(filter, 1, true) then
            shown = shown + 1;
            local selected = override and override.kind == kind and tostring(override.value) == tostring(entry.value);
            if imgui.Selectable(TitleCase(entry.name) .. '##pick' .. i, selected) then
                SetOverride(current, kind, entry.value);
            end
            if imgui.IsItemHovered() then
                imgui.BeginTooltip();
                DrawIconPreview(IconKeyFromOverride({ kind = kind, value = entry.value }), 40);
                imgui.EndTooltip();
            end
            if shown >= 400 then
                imgui.TextDisabled('... more, narrow the filter');
                break;
            end
        end
    end
    imgui.EndChild();
end

-- ============================================
-- Profiles section (config window)
-- ============================================

local profileUi = {
    newName  = { '' },
    selected = nil,       -- selected profile name in the list
    names    = nil,       -- cached ListProfiles() result
    status   = '',
};
local profileSectionChanged = false;

local function RefreshProfileList()
    profileUi.names = ListProfiles();
end

local function DrawProfilesSection()
    imgui.TextColored({ 1.0, 0.85, 0.4, 1.0 }, 'Profiles');

    if imgui.Checkbox('Show profile name on overlay', cfg.showProfileName) then
        profileSectionChanged = true;
    end

    -- Save current binds as a new profile
    imgui.InputText('##newprofile', profileUi.newName, 32);
    imgui.SameLine();
    if imgui.Button('Save as') then
        local ok, result = SaveProfile(profileUi.newName[1]);
        if ok then
            profileUi.status = ('Saved "%s" (%d binds).'):fmt(SanitizeProfileName(profileUi.newName[1]), result);
            profileUi.selected = SanitizeProfileName(profileUi.newName[1]);
            profileUi.newName[1] = '';
            RefreshProfileList();
        else
            profileUi.status = result;
        end
    end

    if profileUi.names == nil then RefreshProfileList(); end

    -- Saved profiles list
    imgui.BeginChild('##profilelist', { 0, 90 }, ImGuiChildFlags_Borders);
    if #profileUi.names == 0 then
        imgui.TextDisabled('No profiles yet.');
    end
    for i, name in ipairs(profileUi.names) do
        local label = name;
        if name == bv.settings.currentProfile then label = name .. '  (active)'; end
        if imgui.Selectable(label .. '##profile' .. i, profileUi.selected == name) then
            profileUi.selected = name;
        end
    end
    imgui.EndChild();

    local hasSelection = profileUi.selected ~= nil and profileUi.names:contains(profileUi.selected);
    if not hasSelection then
        imgui.TextDisabled('Select a profile to load, overwrite, or delete.');
    else
        if imgui.Button('Load') then
            local ok, result = LoadProfile(profileUi.selected);
            profileUi.status = ok and ('Loaded "%s" (%d binds).'):fmt(profileUi.selected, result) or result;
        end
        imgui.SameLine();
        if imgui.Button('Overwrite') then
            local ok, result = SaveProfile(profileUi.selected);
            profileUi.status = ok and ('Overwrote "%s" (%d binds).'):fmt(profileUi.selected, result) or result;
        end
        imgui.SameLine();
        if imgui.Button('Delete') then
            local ok, err = DeleteProfile(profileUi.selected);
            profileUi.status = ok and ('Deleted "%s".'):fmt(profileUi.selected) or (err or 'Could not delete.');
            profileUi.selected = nil;
            RefreshProfileList();
        end
    end

    if profileUi.status ~= '' then
        imgui.TextDisabled(profileUi.status);
    end
    imgui.TextDisabled('Bind cycling with: /bind ^p /bindview next');
end

-- ============================================
-- Config window
-- ============================================

local function DrawConfig()
    if not bv.configOpen then return; end

    local isOpen = { true };
    imgui.SetNextWindowSize({ 340, 0 }, ImGuiCond_FirstUseEver);
    if imgui.Begin('bindview Settings', isOpen, ImGuiWindowFlags_AlwaysAutoResize) then
        local changed = false;

        imgui.TextColored({ 1.0, 0.85, 0.4, 1.0 }, 'Layout');
        if imgui.BeginCombo('Mode', LAYOUT_NAMES[cfg.layoutIndex[1]]) then
            for i, name in ipairs(LAYOUT_NAMES) do
                if imgui.Selectable(name .. '##layout' .. i, i == cfg.layoutIndex[1]) then
                    cfg.layoutIndex[1] = i;
                    changed = true;
                end
            end
            imgui.EndCombo();
        end
        if cfg.layoutIndex[1] == 1 then
            if imgui.Checkbox('Show empty keys', cfg.showEmptyKeys) then changed = true; end
        end
        if imgui.SliderInt('Columns (grid / overflow)', cfg.columns, 1, 20) then changed = true; end
        if imgui.SliderInt('Icon size', cfg.iconSize, 16, 64) then changed = true; end
        if imgui.SliderInt('Padding', cfg.padding, 0, 16) then changed = true; end
        if imgui.SliderFloat('Key text scale', cfg.keyScale, 0.6, 2.0, '%.2f') then changed = true; end
        if imgui.Checkbox('Key label badge', cfg.keyBadge) then changed = true; end
        if imgui.ColorEdit4('Key label color', cfg.keyColor) then changed = true; end
        if imgui.SliderFloat('Background alpha', cfg.alpha, 0.0, 1.0, '%.2f') then changed = true; end

        imgui.Separator();
        imgui.TextColored({ 1.0, 0.85, 0.4, 1.0 }, 'Display');
        if imgui.Checkbox('Visible', cfg.visible) then changed = true; end
        if imgui.Checkbox('Lock position', cfg.locked) then changed = true; end
        if imgui.Checkbox('Show action names under icons', cfg.showNames) then changed = true; end
        if imgui.Checkbox('Show target on slot (<t>, <stpc>...)', cfg.showTarget) then changed = true; end
        if imgui.Checkbox('Show recast timers', cfg.showRecast) then changed = true; end

        imgui.Separator();
        if imgui.Button('Reset position') then
            bv.settings.position_x = defaultSettings.position_x;
            bv.settings.position_y = defaultSettings.position_y;
            bv.positionApplied = false;
            changed = true;
        end
        imgui.SameLine();
        if imgui.Button('Reload icons') then
            ClearTextures();
            for _, b in ipairs(bv.binds) do
                b.iconKey = nil;
                b.recastRef = nil;
                b.recastExpiry = nil;
            end
        end
        imgui.SameLine();
        if imgui.Button('Close') then
            isOpen[1] = false;
        end

        imgui.TextDisabled(('%d binds captured'):fmt(#bv.binds));

        imgui.Separator();
        DrawProfilesSection();
        if profileSectionChanged then
            profileSectionChanged = false;
            changed = true;
        end

        imgui.Separator();
        DrawIconPicker();

        if changed then
            SyncSettingsFromConfig();
            SaveSettings();
        end
    end
    imgui.End();

    if not isOpen[1] then
        bv.configOpen = false;
    end
end

ashita.events.register('d3d_present', 'present_cb', function()
    DrawOverlay();
    DrawConfig();
end);

-- ============================================
-- Lifecycle
-- ============================================

ashita.events.register('load', 'load_cb', function()
    bv.positionApplied = false;
end);

ashita.events.register('unload', 'unload_cb', function()
    SaveSettings();
end);

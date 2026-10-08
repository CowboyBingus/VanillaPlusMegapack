-- Match Your Colors: the game's weapon paint schemes as paint schemes for the Helldiver (the Paint Scheme option).
--
-- Each scheme is the weapon customization item of the PaintScheme slot; it swaps the weapons' material LUTs, one
-- shared 8 x 23 LUT per material class. Its m_weapon LUT follows one row convention in all 11 schemes: r0 body
-- paint, r1 the secondary paint (the camo row in camo schemes), r2 cloth (mode 1), r3-r5 detail paints, r6-r7 metal.
-- The scheme -> LUT link lives in the game's encrypted settings, so it is listed here (archive from the game's
-- hash lookup, LUT name); the LUT itself is read from the game's bundles at runtime (KB match-your-colors-schemes-sync,
-- Steam build 25480438).
--
-- A scheme becomes a source item of three groups for src/matcher.lua: primary (share PRIMARY: r0, or the camo row
-- r1), secondary (SECONDARY: r1, or r0) and cloth (CLOTH: r2, counted as undersuit, so it goes to undersuit and dark
-- structure parts only when it is a dark neutral). Rows that take a camo row copy its colors and camo columns
-- (src/recolor.lua). Nothing here runs per frame.
local Schemes = {}

Schemes.PRIMARY, Schemes.SECONDARY, Schemes.CLOTH = 0.6, 0.25, 0.15

-- In the game's order (Paint_Solid, then Paint_Camo interleaved as its customization list shows them). text: the
-- en.lua key of its name; camo: the camo row (r1) is the primary.
Schemes.LIST = {
    {id = 'helldiver', text = 'scheme.helldiver', archive = 'd7353578fc8df474', lut = '9f09bf697ec501a0'},
    {id = 'forest', text = 'scheme.forest', archive = '5ea029039de33479', lut = '1bd978d3960f3b97'},
    {id = 'forest_camo', text = 'scheme.forest_camo', archive = '6b79bbb20a303671', lut = '72ba1e791ed0a166',
     camo = true},
    {id = 'arctic', text = 'scheme.arctic', archive = 'bbba973314a3b3f1', lut = '642d22bee762b6bd'},
    {id = 'arctic_camo', text = 'scheme.arctic_camo', archive = '4acfca3e8fe5a0e6', lut = 'b0bfc364b70a43d4',
     camo = true},
    {id = 'desert', text = 'scheme.desert', archive = '09510b899fdd4a13', lut = 'f8d36a490676ec43'},
    {id = 'desert_camo', text = 'scheme.desert_camo', archive = '444ff90550d8c91b', lut = 'ade6c402bf0030c9',
     camo = true},
    {id = 'urban', text = 'scheme.urban', archive = '9bdac09de7dd4b69', lut = '650af9d69b7696bc'},
    {id = 'urban_camo', text = 'scheme.urban_camo', archive = '13455c609ccd9960', lut = 'beaa6a092dde05d8',
     camo = true},
    {id = 'night', text = 'scheme.night', archive = '802cc92e12493f63', lut = '7bb4597035f23c80'},
    {id = 'venus', text = 'scheme.venus', archive = '855ea06e998711df', lut = '7b9692abb86210b4'},
}

-- The scheme of an option value: 0 none, 1-11 the list's entries; nil for anything else.
function Schemes.get(index)
    if type(index) ~= 'number' or index % 1 ~= 0 then return nil end
    return Schemes.LIST[index]
end

-- The rows of a scheme's source item, primary first: {row index, share, undersuit share}.
function Schemes.roles(scheme)
    local primary, secondary = 0, 1
    if scheme.camo then primary, secondary = 1, 0 end
    return {{primary, Schemes.PRIMARY, 0}, {secondary, Schemes.SECONDARY, 0}, {2, Schemes.CLOTH, Schemes.CLOTH}}
end

-- The scheme as a source item for src/matcher.lua. lut: {values, width, height} (its m_weapon LUT); Colour: the
-- src/colour.lua module; colour: its color model (Colour.new, row_info); Matcher: src/matcher.lua. Its rows are
-- unmeasured and read as paint: their color is their mean albedo, never darkened as metal (the camo rows carry a
-- metallic bias of up to 4.2 that only shows on worn edges). A camo row carries copy = true (the rows taking it copy
-- its colors and camo, src/recolor.lua).
function Schemes.item(Matcher, Colour, colour, scheme, lut)
    local rows = {}
    for _, role in ipairs(Schemes.roles(scheme)) do
        local r = role[1]
        if r < lut.height then
            local _, _, _, _, camo, mode, _, ar, ag, ab = colour.row_info(lut.values, lut.width, r)
            local L, a, b = Colour.linear_to_lab(ar, ag, ab)
            rows[#rows + 1] = {key = scheme.lut .. ':' .. r, lut = scheme.lut, row = r, area = role[2],
                               under = role[3], L = L, a = a, b = b, metal = false, camo = camo, mode = mode,
                               full = false, ar = ar, ag = ag, ab = ab, copy = camo or nil}
        end
    end
    return Matcher.item(rows, true, nil, nil)
end

-- Runs once per scheme and job: interpreted (it must not add traces to the LuaJIT code cache every mod shares).
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({Schemes.get, Schemes.roles, Schemes.item}) do jit.off(fn, true) end
end

return Schemes

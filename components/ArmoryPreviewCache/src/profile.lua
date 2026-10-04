local M={}
function M.decode(text,build)
    local items={}
    if type(text)~='string' or #text>65536 or text:sub(-1)~='\n' then return items,false end
    local header,body=text:match('^([^\r\n]+)\r?\n(.*)$')
    local legacy=header=='ArmoryPreviewCache1 '..build
    if not legacy and header~='ArmoryPreviewCache2 '..build then return items,false end
    local seen={}
    for line in body:gmatch('[^\r\n]+')do
        local base,extra=line:match('^([^|]+)|?(.*)$')
        local kind,id
        if base then kind,id=base:match('^([0-4]):([0-9a-f]+)$')end
        if kind and #id==16 and not seen[base] and id~='0000000000000000' and (not legacy or extra=='')then
            local attachments,valid,unique={},true,{}
            if extra~=''then
                if extra:find('[^0-9a-f,]') or extra:sub(1,1)==',' or extra:sub(-1)==',' or extra:find(',,',1,true)then valid=false end
                for value in extra:gmatch('[^,]+')do
                    if #value~=16 or value=='0000000000000000' or unique[value] or #attachments>=10 then valid=false;break end
                    unique[value]=true;attachments[#attachments+1]=value
                end
            end
            if valid then
                seen[base]=true;items[#items+1]={kind=tonumber(kind),id=id,attachments=not legacy and attachments or nil}
            end
            if #items==192 then break end
        end
    end
    return items,true
end
function M.encode(items,build)
    local lines={'ArmoryPreviewCache2 '..build}
    for _,item in ipairs(items)do
        lines[#lines+1]=item.kind..':'..item.id..'|'..table.concat(item.attachments or {},',')
    end
    return table.concat(lines,'\n')..'\n'
end
function M.options(text)
    local result={enabled=true,prewarm=true,images=true,disk=false,verify_gate=false}
    for key,value in (text or ''):gmatch('([%w_]+)%s*=%s*([01])')do
        if key=='enabled' or key=='prewarm' or key=='images' or key=='verify_gate'then result[key]=value=='1'end
    end
    return result
end
return M

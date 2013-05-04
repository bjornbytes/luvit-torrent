local bencode = {}

function bencode.decode(str)
  local first = str:sub(1,1)

  if first == 'd' then return bencode.decodeDictionary(str)
  elseif first >= '0' and first <= '9' then return bencode.decodeString(str)
  elseif first == 'i' then return bencode.decodeInteger(str)
  elseif first =='l' then return bencode.decodeList(str)
  else return nil end
end

function bencode.decodeDictionary(str)
  local dict, el = {}
  local str, k = str:sub(2)
  while str do
    k, str = bencode.decodeString(str)
    v, str = bencode.decode(str)
    dict[k] = v
    if str:sub(1,1) == 'e' then return dict, str end
  end
end

function bencode.decodeList(str)
  local list, el = {}
  local str = str:sub(2)
  while str do
    el, str = bencode.decode(str)
    table.insert(list, el)
    if str:sub(1,1) == 'e' then return list, str end
  end
end

function bencode.decodeInteger(str)
  local result
  local s = str:gsub('i(-?%d+)e', function(n)
    result = n
    return ''
  end)
  return tonumber(result), str:sub(3 + result:len())
end

function bencode.decodeString(str)
  local len
  local s = str:gsub('(%d+):', function(n)
    len = n
    return ''
  end, 1)
  return s:sub(1, len), s:sub(len+1)
end

return bencode
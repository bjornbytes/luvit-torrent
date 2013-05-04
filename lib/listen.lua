local net = require('net')

local listen = {}

function listen:listenOn(port, callback)
  listen.server = net.createServer(function(client)
    -- 
  end)
  
  listen.server:listen(port, function()
    callback(listen.server:address().port)
  end)
end

function listen:getPort(callback, port)
  port = port or 6881
  if not listen.server then return listen:listenOn(port, callback) end
  return callback(listen.server:address().port)
end

function listen:getPortSync()
  if listen.server then return listen.server:address().port end
end

return listen
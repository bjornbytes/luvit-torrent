local net = require('net')

local listen = {}


-- Creates a server listening on port.
-- Once the server is started, executes callback with port
-- as its single parameter.
function listen:listenOn(port, callback)
  listen.server = net.createServer(function(client)
    -- 
  end)
  
  listen.server:listen(port, function()
    callback(listen.server:address().port)
  end)
end


-- Asynchronously returns the port the listen server is listening on.
-- If the listen server is not listening, it will first start the listen server.
-- The port the server listens on (in the case where the server is not
-- currently listening) can be specified by the port parameter.
function listen:getPort(callback, port)
  port = port or 6881
  if not listen.server then return listen:listenOn(port, callback) end
  return callback(listen.server:address().port)
end


-- Synchronously eturns the port the listen server is listening on,
-- or nil if it isn't listening on a port.
function listen:getPortSync()
  if listen.server then return listen.server:address().port end
end


return listen
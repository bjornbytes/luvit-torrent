local Torrent = require('./torrent')

-- Place a torrent named sample.torrent in the same directory
-- as this file.
-- Parse its metainfo with:
--   luvit test.lua
-- We are not outputting the info dictionary because it
-- contains a large amount of binary data.
local t = Torrent:new('sample.torrent')
t:start()
local timer = require('timer')

local Object = require('core').Object

local Pipeline = Emitter:extend()

function Pipeline:initialize(size)
  self.queue = {}
  self.pending = {}
  self.size = size or 1
  self.next = function(self) local x = self.queue[1] table.remove(self.queue, 1) return x end
end

local function fill(self)
  while #self.pending < self.size do
    if #self.queue == 0 then break end -- We don't have anything to add to the pipeline.
    
    local job = self:next()
    job.run(job.obj, job.done)
    
    if job.maxlife and job.maxlife > 0 then timer.setTimeout(job.maxlife, job.death) end
  end
end

function Pipeline:add(obj, run, done, maxlife, death)
  self.queue[#self.queue + 1] = {
    obj = obj,
    run = run,
    done = done,
    maxlife = maxlife,
    death = death
  }
  
  self:fill()
end

return Pipeline
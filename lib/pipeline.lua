local table = require('table')

local timer = require('timer')

local Emitter = require('core').Emitter

local Pipeline = Emitter:extend()

function Pipeline:initialize(size)
  self.queue = {}
  self.pending = {}
  self.size = size or 1
  self.next = function(self) local x = self.queue[1] table.remove(self.queue, 1) return x end
end

function Pipeline:fill()
  while #self.pending < self.size do
    if #self.queue == 0 then break end -- We don't have anything to add to the pipeline.
    
    local job = self:next()
    table.insert(self.pending, job)
    
    job.run(job.obj, function(...)
      
      if job.dead then return end
      
      -- Clear an expriation timeout if there is one.
      if job.deathTimer then timer.clearTimer(job.deathTimer) end
      
      -- Run the callback.
      if job.done then job.done(...) end
      
      -- Remove the job after it's finished.  Hate to do a linear pass here.
      local i
      for i = 1, #self.pending do
        if self.pending[i] == job then
          table.remove(self.pending, i)
          break
        end
      end
      
      -- Start more jobs.
      self:fill()
    end)
    
    if job.maxlife and job.maxlife > 0 then
      job.deathTimer = timer.setTimeout(job.maxlife, function()
        if job.death then job.death() end
        
        for i = 1, #self.pending do
          if self.pending[i] == job then
            table.remove(self.pending, i)
            break
          end
        end
        
        self:fill()
        
        job.dead = true
      end)
    end
  end
end

function Pipeline:add(obj, run, done, maxlife, death)
  self.queue[#self.queue + 1] = {
    obj = obj,
    run = run,
    done = done,
    maxlife = maxlife,
    death = death,
    deathTimer = nil
  }
  
  self:fill()
end

return Pipeline
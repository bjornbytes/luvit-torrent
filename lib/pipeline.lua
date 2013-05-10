local table = require('table')

local timer = require('timer')

local Object = require('core').Object

local Pipeline = Object:extend()

function Pipeline:initialize(rate, run)
  self.queue = {}
  self.rate = rate
  self.run = run
  self.nextTimer = nil
end

function Pipeline:add(obj, weight)
  table.insert(self.queue, {obj = obj, weight = weight})
  if self.nextTimer == nil then self:pipe() end
end

function Pipeline:pipe()
  if #self.queue == 0 then self.nextTimer = nil return end
  
  local job = self.queue[1]
  table.remove(self.queue, 1)
  self.run(job.obj)
  
  self.nextTimer = timer.setTimeout((job.weight / self.rate) * 1000, self:pipe)
end  

return Pipeline
function love.conf(t)
  t.identity = "PartyPort"
  t.version = "11.5"
  t.window.title = "PartyPort"
  t.window.width = 390
  t.window.height = 760
  t.window.minwidth = 320
  t.window.minheight = 480
  t.window.resizable = true
  t.window.highdpi = true
  t.window.usedpiscale = true
  t.modules.joystick = false
  t.modules.physics = false
  t.modules.audio = false
  t.modules.sound = false
  t.modules.video = false
end

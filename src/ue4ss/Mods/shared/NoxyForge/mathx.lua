local M = {}
function M.finite(x) return type(x)=="number" and x==x and x~=math.huge and x~=-math.huge end
function M.vector(v)
    return type(v)=="table" and M.finite(v.X) and M.finite(v.Y) and M.finite(v.Z)
end
function M.clamp(x,low,high)
    if not M.finite(x) then return nil,"non-finite number" end
    return math.max(low,math.min(high,x))
end
function M.distance(a,b)
    if not M.vector(a) or not M.vector(b) then return nil,"invalid vector" end
    local x,y,z=a.X-b.X,a.Y-b.Y,a.Z-b.Z
    return math.sqrt(x*x+y*y+z*z)
end
-- A softened, capped acceleration remains finite at the centre.
function M.attraction(position,centre,options)
    if not M.vector(position) or not M.vector(centre) then return nil,"invalid vector" end
    options=options or {}
    local radius=options.radius or 700
    local maximum=options.acceleration or 350
    local softness=options.softness or 120
    local swirl=options.swirl or 0
    if not M.finite(radius) or not M.finite(maximum) or not M.finite(softness) or not M.finite(swirl)
        or radius<=0 or maximum<0 or softness<=0 then return nil,"invalid force limits" end
    local x,y,z=centre.X-position.X,centre.Y-position.Y,centre.Z-position.Z
    local d=math.sqrt(x*x+y*y+z*z)
    if d<0.001 or d>radius then return {X=0,Y=0,Z=0} end
    local magnitude=math.min(maximum,maximum*softness*softness/(d*d+softness*softness))
    local horizontal=math.sqrt(x*x+y*y)
    local vx,vy,vz=x/d*magnitude,y/d*magnitude,z/d*magnitude
    if horizontal>0.001 then vx=vx-y/horizontal*swirl;vy=vy+x/horizontal*swirl end
    local total=math.sqrt(vx*vx+vy*vy+vz*vz)
    if total>maximum and total>0 then local f=maximum/total;vx=vx*f;vy=vy*f;vz=vz*f end
    return {X=vx,Y=vy,Z=vz}
end
function M.offset(a,b) return {X=a.X+b.X,Y=a.Y+b.Y,Z=a.Z+b.Z} end
return M

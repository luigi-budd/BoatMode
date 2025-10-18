/*
	--TODO:
	-visual feedback for when allowboat is disabled
	-[done]general vfx
	-[done]drifting cancels when slow
	-[done]trap items (like bananas) float
	-[done]sector special that activates a dolphin jump
	-[done]adjustable propeller sprites thru mapheader
	-[done]items arent collected when respawning on a boat section
	-stray boosts? some boost doesnt decay on boat
*/
--apologies for the messy code lol, i didnt expect this to be so big

/*
	--this is an addon made by luigi budd/EpixGamer21
	
	special thanks:
	* members of the kart krew server for giving feedback as i developed
	  this mod, thank you!
	
	* mario kart 8 - sounds
	* L_DecimalFixed - https://wiki.srb2.org/wiki/User:Clairebun/Sandbox/Common_Lua_Functions
*/

local BOAT_2POINT4 = false
local function checkVersion()
	BOAT_2POINT4 = (SUBVERSION >= 4)
end

addHook("MapLoad",checkVersion)
addHook("NetVars",function(n) BOAT_2POINT4 = n($); end)
checkVersion()

if BOAT_2POINT4
	error("BoatMode is unsupported in 2.4.",2) --for now...
end

-- no tofixed in rr unfortunately
-- https://wiki.srb2.org/wiki/User:Clairebun/Sandbox/Common_Lua_Functions
rawset(_G, 'L_DecimalFixed', function(str)
	if str == nil return nil end
	local dec_offset = string.find(str,'%.')
	if dec_offset == nil
		return (tonumber(str) or 0)*FRACUNIT
	end
	local whole = tonumber(string.sub(str,0,dec_offset-1)) or 0
	local decstr = string.sub(str,dec_offset+1)
	local decimal = tonumber(decstr) or 0

	if(decimal==0)
		decstr = "0"
	end

	whole = $ * FRACUNIT
	local dec_len = string.len(decstr)
	decimal = $ * FRACUNIT / (10^dec_len)
	return whole + decimal
end)

local TR = TICRATE

sfxinfo[ freeslot("sfx_bt_st") ].caption = "/"
sfxinfo[ freeslot("sfx_bt_de") ].caption = "/"

freeslot("SPR_BT__","S_BOAT_PROP","S_BOAT_PROP_OV","MT_BOAT_PROP")
states[S_BOAT_PROP] = {
	sprite = SPR_BT__,
	frame = A|FF_PAPERSPRITE,
	tics = -1,
	nextstate = S_BOAT_PROP
}
states[S_BOAT_PROP_OV] = {
	sprite = SPR_BT__,
	frame = B|FF_PAPERSPRITE,
	tics = -1,
	nextstate = S_BOAT_PROP_OV
}
mobjinfo[MT_BOAT_PROP] = {
	flags = MF_NOGRAVITY|MF_NOCLIPHEIGHT|MF_NOCLIP|MF_NOCLIPTHING|MF_NOSQUISH,
	radius = 24*FU,
	height = 48*FU,
	spawnstate = S_BOAT_PROP,
	deathstate = S_BOAT_PROP,
	spawnhealth = 1,
}
local PROPEL_EASE = TR/3
local PROPEL_OFFSET = 10
local PROPEL_ANGDIFF = FixedAngle(4*FU)

local function sign(a)
	return (a ~= 0) and (a < 0 and -1 or 1) or 0
end

local function getattrib(name,default,allowstring)
	if not mapheaderinfo[gamemap]
		return default
	end
	
	local attrib = mapheaderinfo[gamemap][name]
	if attrib == nil
		return default
	end
	if attrib:lower() == "true"
		return true
	elseif attrib:lower() == "false"
		return false
	elseif allowstring
		return attrib
	end
	return default
end

local function playwatersound(me)
	S_StartSound(me,
		(me.eflags & MFE_UNDERWATER) and
		P_RandomRange(sfx_bubbl1,sfx_splash)
		or
		sfx_wslap
	)
end
local function spawnsplish(me)
	if (me.eflags & MFE_UNDERWATER) then return end
	
	local splish = P_SpawnMobjFromMobj(me,0,0,0,
		(me.eflags & MFE_TOUCHLAVA) and MT_LAVASPLISH or MT_SPLISH
	)
	splish.destscale = me.scale
	P_SetScale(splish, me.scale)
	splish.renderflags = $|RF_SEMIBRIGHT
	
	if P_MobjFlip(me) == -1
		P_SetOrigin(splish, splish.x,splish.y,
			me.waterbottom - splish.height
		)
		splish.flags2 = $|MF2_OBJECTFLIP
		splish.eflags = $|MFE_VERTICALFLIP
	else
		P_SetOrigin(splish, splish.x,splish.y,
			me.watertop
		)
	end
end

--unexposed bullshit
local function wirecutspeed(p)
	local req = K_GetKartSpeed(p,false,false) * 2
	--we're never on offroad, and we cant access bot vars, so this is all we need to do
	return req
end

--MORE unexposed bullshit
local KART_FULLTURN = 800
local function steering(input, destSteer)
	local amount = KART_FULLTURN / 3
	local diff = destSteer - input
	local output = input
	
	if ((input > 0 and destSteer < 0) or (input < 0 and destSteer > 0))
		local countersteer = min(KART_FULLTURN, abs(input))
		amount = max(countersteer, $)
	end
	
	if abs(diff) <= amount
		output = destSteer
	else
		if diff < 0
			output = $ - amount
		else
			output = $ + amount
		end
	end
	
	return output
end

--wouldnt you believe it
local function sparkstage(p,stage)
	return K_GetKartDriftSparkValue(p)*stage
end

local BT_FASTFALLMASK = BT_ACCELERATE|BT_BRAKE
local BT_SPINDASHMASK = BT_FASTFALLMASK|BT_DRIFT
local RESPAWNST_DROP = RESPAWNST_DROP or 2
local function canboat(p)
	local candoit = true
	
	/*
	if p.fastfall ~= 0
		candoit = false
	end
	if (p.cmd.buttons & BT_FASTFALLMASK == BT_FASTFALLMASK)
		candoit = false
	end
	*/
	if p.markedfordeath
		candoit = false
	end
	if p.tumblebounces
		candoit = false
	end
	if (p.playerstate ~= PST_LIVE)
		candoit = false
	end
	if (p.respawn.state ~= 0)
	--RESPAWNST_DROP, the drop dash
	and (p.respawn.state ~= RESPAWNST_DROP)
		candoit = false
	end
	if (p.boatvars and not p.boatvars.allowboat)
		candoit = false
	end
	if (p.curshield == KSHIELD_TOP)
		candoit = false
	end
	
	return candoit
end

local FIRSTRAINBOWCOLOR = FIRSTRAINBOWCOLOR or SKINCOLOR_PINK
local function rainbowcolor(time)
	return FIRSTRAINBOWCOLOR + (time % (FIRSTSUPERCOLOR - FIRSTRAINBOWCOLOR))
end
local function sparkcolor(p,spark)
	local dsone = sparkstage(p,1)
	local dstwo = sparkstage(p,2)
	local dsthree = sparkstage(p,3)
	local dsfour = sparkstage(p,4)
	local c = SKINCOLOR_GOLD
	
	if spark < 0
		c = SKINCOLOR_SILVER
	elseif spark >= dsfour
		if spark <= dsfour+(32*3)
			c = SKINCOLOR_SILVER
		else
			--Please be exposed...
			--With Ring Racers? No way!
			c = rainbowcolor(leveltime)
		end
	elseif spark >= dsthree
		if spark <= dsthree+(16*3)
			c = SKINCOLOR_TAFFY
		elseif spark <= dsthree+(32*3)
			c = SKINCOLOR_NOVA
		else
			c = SKINCOLOR_BLUE
		end
	elseif spark >= dstwo
		if spark <= dstwo+(32*3)
			c = SKINCOLOR_TANGERINE
		else
			c = SKINCOLOR_KETCHUP
		end
	elseif spark >= dsone
		if spark <= dsone+(32*3)
			c = SKINCOLOR_TAN
		else
			c = SKINCOLOR_GOLD
		end
	end
	return c
end

--K_DriftDustHandling is exposed, but doesnt run while airborne
local function driftdust(p,me)
	if (leveltime % 2) then return end
	if (p.speed < 5*me.scale) then return end
	
	local spawnrange = FixedDiv(me.radius,me.scale) >> FRACBITS
	
	local angle = me.angle
	if (p.cmd.forwardmove < 0) angle = $ + ANGLE_180 end
	local angdiff = abs(angle - R_PointToAngle2(0,0,p.rmomx,p.rmomy))
	--over 180?
	if angdiff < 0 then angdiff = InvAngle($); end
	
	if AngleFixed(angdiff) > 40*FU
		local spawnx = P_RandomRange(-spawnrange,spawnrange) << FRACBITS
		local spawny = P_RandomRange(-spawnrange,spawnrange) << FRACBITS
		local speedrange = 2
		local dust = P_SpawnMobjFromMobj(me,spawnx,spawny,0,MT_DRIFTDUST)
		dust.momx = FixedMul(me.momx + (P_RandomRange(-speedrange,speedrange)*me.scale), FU*3/4)
		dust.momy = FixedMul(me.momy + (P_RandomRange(-speedrange,speedrange)*me.scale), FU*3/4)
		dust.momz = P_MobjFlip(me) * P_RandomRange(1,4)*me.scale
		P_SetScale(dust, me.scale/2)
		dust.destscale = me.scale*3
		dust.scalespeed = me.scale/12
		if P_RandomChance(FU/2)
			dust.state = S_SPINDUST_BUBBLE1
		else
			dust.state = S_DRIFTWARNSPARK1
			
			local driftval = K_GetKartDriftSparkValue(p)
			local warntime = driftval/3
			local dc = p.driftcharge
			local c = SKINCOLOR_NONE
			local rainbow = false
			
			if dc >= 0
				dc = $ + warntime
			end
			c = sparkcolor(p,dc)
			if (dc > (4*driftval)+(32*3))
				rainbow = true
			end
			
			if c ~= SKINCOLOR_NONE
				dust.color = c
				dust.colorized = rainbow
			end
		end
		
		if (leveltime % 6 == 0)
			playwatersound(me)
			spawnsplish(me)
		end
	end
end

-- t8ierufdgy7z7gf
local function K_AwardPlayerRings(p, rings, overload)
	if not overload
		local totalrings = (p.rings + p.pickuprings) + p.superring
		
		if totalrings + rings > 20
			if totalrings >= 20 then return end
			rings = 20 - totalrings
		end
	end
	
	local superring = p.superring + rings
	if superring > p.superring
		p.superring = superring
	end
end

local function getdriftslide(p,temp)
	if p.boatdriftslide == nil then return 0; end
	if (p.drift == 0) then return 0; end
	local dsign = sign(p.drift)
	if dsign == -1 -- special handling
		local slide = (1<<16) - p.boatdriftslide -- not fracbits
		if abs(p.steering) == slide
			return -slide;
		end
	elseif p.steering == p.boatdriftslide
		return p.boatdriftslide
	end
	return 0;
end

local function setstate(me,st)
	me.state = st
	
	if me.boat_animvars.state ~= st
		me.boat_animvars.state = st
		me.boat_animvars.frame = me.frame & FF_FRAMEMASK
		me.boat_animvars.tics = me.tics
		me.boat_animvars.startingtics = me.tics
	end
	--me.tics = -1
end

local BT_LOOKBACK = BT_LOOKBACK or (1<<5)
local function animroutine(p,me)
	if me.boat_animvars == nil
		me.boat_animvars = {
			startingtics = 0,
			tics = 0,
			frame = A,
			state = -1,
		}
	end
	local anim = me.boat_animvars
	
	--turning and whatnot are already handled by the game,
	--the tiered driving animations are what we need to handle
	local turndir = 0
	local minturn = KART_FULLTURN/8
	
	local fastspeed = K_GetKartSpeed(p, false, true)
	local speedthreshold = 8*me.scale
	
	if not ((p.cmd.buttons & BT_LOOKBACK)
	--vanilla bug where looking back wouldnt do the drift in/out anims
	and (p.drift == 0))
		if (p.cmd.turning - getdriftslide(p)) < -minturn
			turndir = -1
		elseif (p.cmd.turning - getdriftslide(p)) > minturn
			turndir = 1
		end
		local dsign = sign(p.drift)
		local slide = p.boatdriftslide
		if dsign == -1 -- special handling
			slide = (1<<16) - p.boatdriftslide -- not fracbits
		end
		if (p.drift ~= 0)
		and sign(p.cmd.turning) == dsign
		and (abs(p.cmd.turning) < slide)
			turndir = -dsign
		end
	end
	if p.drift > 0
		if turndir == -1
			setstate(me,S_KART_DRIFT_L_OUT)
		elseif turndir == 1
			setstate(me,S_KART_DRIFT_L_IN)
		else
			setstate(me,S_KART_DRIFT_L)
		end
	elseif p.drift < 0
		if turndir == -1
			setstate(me,S_KART_DRIFT_R_IN)
		elseif turndir == 1
			setstate(me,S_KART_DRIFT_R_OUT)
		else
			setstate(me,S_KART_DRIFT_R)
		end
	else
		if (p.speed >= fastspeed and p.speed >= (p.lastspeed - speedthreshold))
			if turndir == -1
				setstate(me, S_KART_FAST_R)
			elseif turndir == 1
				setstate(me, S_KART_FAST_R)
			else
				if p.glancedir == -2
					setstate(me, S_KART_FAST_LOOK_R)
				elseif p.glancedir == 2
					setstate(me, S_KART_FAST_LOOK_L)
				elseif p.glancedir == -1
					setstate(me, S_KART_FAST_GLANCE_R)
				elseif p.glancedir == 1
					setstate(me, S_KART_FAST_GLANCE_L)
				else
					setstate(me, S_KART_FAST)
				end
			end				
		else
			if (p.cmd.buttons & BT_ACCELERATE)
			or (p.speed > me.scale)
				if turndir == -1
					setstate(me, S_KART_SLOW_R)
				elseif turndir == 1
					setstate(me, S_KART_SLOW_L)
				else
					if p.glancedir == -2
						setstate(me, S_KART_SLOW_LOOK_R)
					elseif p.glancedir == 2
						setstate(me, S_KART_SLOW_LOOK_L)
					elseif p.glancedir == -1
						setstate(me, S_KART_SLOW_GLANCE_R)
					elseif p.glancedir == 1
						setstate(me, S_KART_SLOW_GLANCE_L)
					else
						setstate(me, S_KART_SLOW)
					end
				end				
			else
				--still
				if turndir == -1
					setstate(me, S_KART_STILL_R)
				elseif turndir == 1
					setstate(me, S_KART_STILL_L)
				else
					if p.glancedir == -2
						setstate(me, S_KART_STILL_LOOK_R)
					elseif p.glancedir == 2
						setstate(me, S_KART_STILL_LOOK_L)
					elseif p.glancedir == -1
						setstate(me, S_KART_STILL_GLANCE_R)
					elseif p.glancedir == 1
						setstate(me, S_KART_STILL_GLANCE_L)
					else
						setstate(me, S_KART_STILL)
					end
				end
			end
		end
	end
	
	if (P_PlayerInPain(p))
		setstate(me,S_KART_SPINOUT)
	end
	
	if anim.tics
		anim.tics = $ - 1
	else
		local numframes = 0
		--probably SPR2_STIL, errors if trying to index
		if me.sprite2 == 0
			numframes = 2
		else
			local spr = skins[p.skin].sprites
			numframes = spr[me.sprite2].numframes
		end
		
		anim.frame = ($ + 1)
		if numframes ~= 0
			anim.frame = $ % numframes
		else
			anim.frame = A
		end
		
		anim.tics = anim.startingtics
	end
	me.frame = ($ &~FF_FRAMEMASK)|anim.frame
end

--you never know
local BT_RESPAWN = BT_RESPAWN or (1<<6)
local IF_USERINGS = IF_USERINGS or 1
local IF_ITEMOUT = IF_ITEMOUT or 2
local IF_EGGMANOUT = IF_EGGMANOUT or 4

local boatvar_defaults = {
	[1] = true,
	[2] = true,
	[3] = true,
	[4] = 0,
	[5] = 0,	-- "speedmul"
}
local SINKTIME = TR*2

local function propellsound(p,me)
	if me.boat_sound == nil then me.boat_sound = 0 end
	
	me.boat_sound = $ + FixedDiv(p.speed, K_GetKartSpeed(p,false,true)*5)
	while (me.boat_sound > FU)
		me.boat_sound = $ - FU
		
		playwatersound(me)
		spawnsplish(me)
		me.boat_bubblefx = max($ + 2, 7) 
	end
	
	if (p.speed < me.scale)
	and (p.watertreading)
		if P_RandomChance(FU/2) and (leveltime % TR == 0)
			S_StartSound(me,sfx_floush)
		end
	end
end

--THIS IS USED DO NOT DELETE
local function canuseitem(p)
	return (p.mo.health > 0
		and not p.spectator
		and not P_PlayerInPain(p)
		--and not mapreset
		and (leveltime > introtime)
	)
end

local function candropdash(p)
	if not (p.cmd.buttons & BT_ACCELERATE)
		return false
	end
	--why?
	if (p.spinouttimer)
		return false
	end
	if (p.curshield == KSHIELD_TOP)
		return false
	end
	return true
end

local ACCEL_KICKSTART = ACCEL_KICKSTART or 35
local TRICKSTATE_NONE = 0
local TRICKSTATE_READY = TRICKSTATE_READY or 1
local TRICKSTATE_FORWARD = TRICKSTATE_FORWARD or 2
local TRICKSTATE_BACK = TRICKSTATE_BACK or 5
--UGH!!!
addHook("PlayerCmd",function(p, cmd)
	if (p.boatdriving)
	and (p.boatcontrols)
	and (p.drift ~= 0)
		--do turning and counterturning
		local steering = cmd.turning
		if steering ~= 0
		and sign(steering) ~= sign(p.drift)
			steering = $ / 4
		end
		
		cmd.turning = steering
		
		--drift sliding
		cmd.turning = $ + p.boatdriftslide
	end
end)

addHook("PlayerThink",function(p)
	if not (p.mo and p.mo.valid) then return end
	
	if not (mapheaderinfo[gamemap] and mapheaderinfo[gamemap].boat ~= nil) then return end
	
	if (p.respawn.state == RESPAWNST_DROP)
		--emulate drop dash for boat controls
		if not (p.respawn.timer > 0)
			
			if (candropdash(p))
				p.fakedropdash = $ + 1
			else
				p.fakedropdash = 0
			end
			
			--dont play the sound since the game already handles that
		end
	else
		p.fakedropdash = 0
	end
	
	local me = p.mo
	local gravflip = P_MobjFlip(me)
	me.boat_rollangle = $ or 0
	
	--unexposed bullshit
	p.steering = p.cmd.turning /*steering(
		p.steering ~= nil and p.steering or 0,
		p.cmd.turning
	)*/
	p.boatdriftslide = (FixedAngle(p.drift*FU)/3) >> 16
	
	--we also have to emulate p.kickstartaccel too...
	if p.kickstartaccel == nil then p.kickstartaccel = 0 end
	if not (p.pflags & PF_KICKSTARTACCEL)
		p.kickstartaccel = 0
	elseif (p.cmd.buttons & BT_ACCELERATE)
		if (not p.exiting and not (p.oldcmd.buttons & BT_ACCELERATE)
		and (p.cmd.buttons & BT_SPINDASHMASK ~= BT_SPINDASHMASK)
		and (p.trickpanel ~= TRICKSTATE_READY))
			p.kickstartaccel = 0
		elseif p.kickstartaccel < ACCEL_KICKSTART
			p.kickstartaccel = $ + 1
		else
			p.kickstartaccel = ACCEL_KICKSTART + 1
		end
	elseif (p.kickstartaccel < ACCEL_KICKSTART)
		p.kickstartaccel = 0
	else
		p.kickstartaccel = ACCEL_KICKSTART + 1
	end
	
	if (p.boatvars == nil)
	--always assume these are default when designing triggers
	or (p.respawn.state ~= 0)
	or (p.playerstate ~= PST_LIVE)
		p.boatvars = {
			--player dips down when they mini turbo
			driftdip	= getattrib("boat_driftdip", 		boatvar_defaults[1]),
			allowboat	= getattrib("boat_boatonbydefault", boatvar_defaults[2]),
			dolphinjump	= getattrib("boat_dolphinjump",		boatvar_defaults[3]),
			speedstack	= getattrib("boat_speedincrease", 	boatvar_defaults[4]),
			speedmul	= L_DecimalFixed(getattrib("boat_speedmul", 		boatvar_defaults[5], true)),
		}
	end
	
	me.waterblock = nil
	for fof in me.subsector.sector.ffloors()
		if not (fof.flags & FF_EXISTS) then continue end
		if not (fof.flags & FOF_SWIMMABLE) then continue end
		
		local top = fof.topheight
		if fof.t_slope
			top = P_GetZAt(fof.t_slope, me.x,me.y)
		end
		
		local bot = fof.bottomheight
		if fof.b_slope
			bot = P_GetZAt(fof.b_slope, me.x,me.y)
		end
		
		if me.z > top then continue end
		if me.z+me.height < bot then continue end
		
		me.waterblock = fof
		break
	end
	
	local wasboating = p.boatdriving
	local wasinwater = p.inwater
	local wastilting = me.boat_tilting
	p.inwater = false
	
	local sink = (me.height / 5)
	
	local sinktofloor = false
	local REALLY_sinktofloor = false
	--items weight you down
	if (p.itemamount)
	and (p.itemflags & IF_ITEMOUT)
		if (p.itemtype == KITEM_BANANA)
		or (p.itemtype == KITEM_ORBINAUT)
		or (p.itemtype == KITEM_JAWZ)
		or (p.itemtype == KITEM_MINE)
		--lul
		or (p.itemtype == KITEM_DROPTARGET)
		or (p.itemtype == KITEM_KITCHENSINK)
			/*
			local floor = (gravflip == -1) and me.ceilingz or me.floorz
			local feet = (gravflip == -1) and (me.z + me.height) or me.z
			extrasink = (feet - floor) * 2
			*/
			sinktofloor = true
		end
	end
	
	local z = me.z
	local predictedtoland = false
	local water_top = me.watertop - sink
	local floorbottom = me.floorz
	
	do	
		local hasspace = true
		if (gravflip == 1)
			if me.ceilingz <= water_top
				hasspace = false
			end
			
			predictedtoland = (z + me.momz <= floorbottom)
		elseif (gravflip == -1)
			water_top = me.waterbottom + sink
			z = me.z+me.height
			floorbottom = me.ceilingz
			
			if me.floorz >= water_top
				hasspace = false
			end
			
			predictedtoland = (z + me.momz >= floorbottom)
		end
		
		--dont init boating if the water's too shallow
		local depth = abs(water_top - floorbottom)
		if not wasinwater
			if (depth < me.height*3/2)
				hasspace = false
			end
		end
		
		if (water_top ~= me.z - 1000*FU)
		and (z < water_top)
		--if youre using regular water sections in your map,
		--toggle the boat with the BOAT_SETPVARS action
		--and hasspace
			p.inwater = true
		end
		
	end
	
	if sinktofloor
	and (p.inwater)
		me.boat_sinkhelper = $ + 1
		
		if me.boat_sinkhelper > SINKTIME
			REALLY_sinktofloor = true
		end
	elseif P_IsObjectOnGround(me)
		me.boat_sinkhelper = 0
	end
	
	local easing = 7
	p.boatdriving = false
	
	p.watertreading = false
	if p.inwater
	and canboat(p)
		--just landed in the water
		if not wasinwater
			if (p.airtime)
				p.lastairtime = p.airtime
			end
			
			-- while fast falling
			if (p.fastfall ~= 0)
				-- allow bubble shield to do this
				if (p.trickpanel > TRICKSTATE_READY)
					P_InstaThrust(me, me.angle,
						(2 * abs(p.fastfall) / 3 + 15 * FU)
					)
					me.hitlag = 3
					S_StartSound(me, sfx_gshba)
					p.fastfall = 0
					p.trickcharge = 0
					p.boataccel = 50
					
					for i = 0, 3
						local arc = P_SpawnMobjFromMobj(me,0,0,0,MT_CHARGEFALL)
						arc.target = me
						arc.extravalue1 = i
					end
					me.momz = 0
				else
					me.momz = $ / 10
				end
			else
				if p.trickpanel
					S_StartSound(me, sfx_s23c)
					
					local award = TR - p.trickboostdecay
					p.trickboost = award
					
					if not (gametyperules & GTR_SPHERES)
						K_AwardPlayerRings(p,
							(TR - p.trickboostdecay) * p.lastairtime/3 / TR,
							true
						)
					end
					if (p.trickpanel == TRICKSTATE_FORWARD)
						p.trickboostpower = $ / 18
					elseif (p.trickpanel ~= TRICKSTATE_BACK)
						p.trickboostpower = $ / 9
					end
					
					me.momz = $ / 16
				end
			end
			if p.trickpanel
				p.trickpanel = TRICKSTATE_NONE
				p.trickboostdecay = 0
			end
		end
		
		local allowfloat = false
		if (abs(water_top - z) < 3*me.scale)
		and abs(me.momz) <= 5*me.scale
		and (me.boat_fastfallhelp == nil)
		and (REALLY_sinktofloor == false)
			allowfloat = true
		end
		
		if allowfloat
			if p.cmd.buttons & BT_FASTFALLMASK == 0
				me.flags = $|MF_NOGRAVITY
				if p.fastfall == 0
					p.fastfall = -gravflip
				end
			end
			me.momz = $*2/3
			
			if abs(me.momz) <= 3*me.scale
				me.momz = $/3
			end
			p.watertreading = true
		--buoyant
		else
			me.flags = $|MF_NOGRAVITY
			local floating = (me.scale*3/2)*gravflip
			local diff = (water_top - z) * gravflip
			if diff < 0
				floating = -$
			end
			if me.boat_fastfallhelp
			or REALLY_sinktofloor
				floating = -$
				
				if P_IsObjectOnGround(me)
				or (me.eflags & MFE_JUSTHITFLOOR)
					floating = 0
					
					p.spindash = 0
					S_StopSoundByID(me,sfx_kc38)
				end
				if REALLY_sinktofloor
					floating = $ / 3
				end
			end
			
			me.momz = $ + floating --FixedDiv(abs(diff/100), abs(floating))
		end
		me.waterskip = max($,3)
		p.boatdriving = true
		
		if me.waterblock
		and me.waterblock[gravflip == 1 and "t_slope" or "b_slope"]
		and (REALLY_sinktofloor == false)
			local slope = me.waterblock[gravflip == 1 and "t_slope" or "b_slope"]
			local angdiff = R_PointToAngle2(0,0,me.momx,me.momy) - slope.xydirection
			
			local disp = P_ReturnThrustY(nil, slope.zangle, P_ReturnThrustX(nil, angdiff, p.speed))
			me.z = $ + disp/2
		end
		
		if p.fastfall ~= 0
			if me.eflags & MFE_JUSTHITFLOOR
			or (p.cmd.buttons & BT_FASTFALLMASK ~= BT_FASTFALLMASK)
				p.fastfall = 0
			end
		end
		
		if not wasboating
		and (not me.boat_tilting
		or not me.health)
			me.boat_transform = 14
			S_StartSound(me,sfx_bt_st,p)
			S_StopSoundByID(me,sfx_bt_de)
			
			me.spritexscale,me.spriteyscale = FU,FU
		end
		me.boat_tilting = true
		
	--cant boat, but under the water
	elseif p.inwater
	and p.boatvars.allowboat
		if (me.flags & MF_NOSQUISH)
			me.spriteyoffset = 0
		end
		
		me.flags = $ &~(MF_NOGRAVITY|MF_NOSQUISH)
		--me.momz = $ * 4/5
		me.boat_tilting = nil
	end
	
	--moved later for kickstart fix
	local sortofrealbuttons = p.cmd.buttons
	p.boataccel = $ or 0
	do
		local forwardmove = p.cmd.forwardmove
		if (p.pflags & PF_KICKSTARTACCEL)
		and p.kickstartaccel >= ACCEL_KICKSTART
			forwardmove = 50
			if p.boatdriving
				p.cmd.buttons = $|BT_ACCELERATE
			end
		end
		
		if (p.nocontrol or p.carry or p.markedfordeath or P_PlayerInPain(p))
		or (p.cmd.buttons & BT_RESPAWN)
		or (me.boat_ebrakehelper)
			forwardmove = 0
			--err 
			p.boataccel = 0
		end
		
		if forwardmove < 0
			forwardmove = $ / 2
			easing = 10
		end
		p.boataccel = $ + ((forwardmove - $) / easing)
		if abs(p.cmd.forwardmove - p.boataccel) <= easing - 1
			p.boataccel = p.cmd.forwardmove
		end
		
		if (me.eflags & MFE_JUSTBOUNCEDWALL)
			p.boataccel = $ / 2
		end
	end
	
	if me.boat_bobtime == nil
		me.boat_bobtime = 0
		me.boat_bobs = 0
	elseif me.boat_bobtime
	and p.inwater
		me.boat_bobtime = $ - 1
	elseif not me.boat_bobtime
		me.boat_bobs = 0
	end

	if P_IsObjectOnGround(me)
	and (me.waterblock == nil)
		me.boat_tilting = false
		me.boat_bobtime = 0
		me.boat_bobs = 0
	end
	if not (me.health) then me.boat_tilting = false; end
	if not (p.boatvars.allowboat) then me.boat_tilting = false; end
	
	if (wasinwater and not p.inwater)
	or (wasboating and not p.boatdriving)
		me.flags = $ &~MF_NOGRAVITY
		
		local cutgrav = true
		if p.fastfall ~= 0
			cutgrav = false
		end
		if (p.trickstate)
			cutgrav = false
		end
		
		--dolphin jumps are limited to drift boosts,
		--for the sake of sticking-to-the-water-surface
		if me.boat_jumpheight ~= nil
			cutgrav = false
		end
		
		if cutgrav
			local frac = min((FU/2) + ((me.boat_bobs*FU)/5), FU)
			me.momz = ease.linear(frac,
				$*3/4, 0
			)
			
			if abs(me.momz) <= 2*me.scale
				me.momz = $/2
			end
			
			me.boat_bobs = $ + 1
			me.boat_bobtime = TR
		else
			if me.boat_jumpheight ~= nil
				if (p.boatvars.allowboat)
					me.momz = me.boat_jumpheight*gravflip
				end
				me.boat_jumpheight = nil
			end
		end
		
		if not P_PlayerInPain(p)
			me.rollangle = 0
		end
		if (me.health)
		and (p.boatvars.allowboat)
			me.boat_tilting = true
		end
	end
	
	if (p.inwater
	or me.boat_tilting)
	and (p.boatvars.allowboat)
	--and (p.trickpanel == TRICKSTATE_NONE)
		local threedspeed = FixedHypot(FixedHypot(me.momx,me.momy),me.momz)
		if p.fastfall ~= 0
			threedspeed = 0
		end
		local lateralspeed = FixedHypot(me.momx,me.momy)
		
		--try not to be so nauseating
		p.tilt = $ / 2
		if threedspeed >= 4*me.scale
		and (p.trickpanel == TRICKSTATE_NONE)
			local angle = R_PointToAngle2(0,0,me.momx,me.momy)
			if (lateralspeed < 5*me.scale
			and p.inwater)
			or (lateralspeed < me.scale)
				angle = me.angle
			end
			local mang = R_PointToAngle2(0,0, FixedHypot(me.momx, me.momy), me.momz)
			mang = InvAngle($)
			
			local dest_roll = FixedMul(
				mang, sin(angle)
			)
			local dest_pitch = FixedMul(
				mang, cos(angle)
			)
			
			--EASE the angles so we dont get weird camera tilt stuff
			--fun fact, P_SetAngle/Pitch/Roll functions exist in lua.
			--			except P_SetPitchRoll which exists in hardcode but isnt exposed...
			local easing = FU/7
			me.roll = $ + FixedMul(dest_roll - $, easing)
			me.pitch = $ + FixedMul(dest_pitch - $, easing)
		else
			me.roll = FixedMul($, FU*4/5)
			me.pitch = FixedMul($, FU*4/5)
		end
		--dont stumble, dork
		if (me.eflags & MFE_JUSTHITFLOOR
		or predictedtoland)
		and (me.waterblock == nil)
		and (me.momz*gravflip < 0)
			me.roll,me.pitch = 0,0
			me.boat_tilting = false
		end
		
		if me.boat_tilttime == nil then me.boat_tilttime = 0; end
		me.boat_tilttime = $ + 1
		if p.inwater
			/*
			local angle = me.angle - ANGLE_90
			local mang = FixedAngle(p.steering*100)*5
			print(p.steering)
			
			targetroll = $ + FixedMul(mang, sin(angle))
			targetpitch = $ + FixedMul(mang, cos(angle))
			*/
			local steering = (p.drift ~= 0) and p.steering or -p.steering
			if (p.drift ~= 0)
				steering = 160*p.drift + $*2/3
				if not p.boatvars.driftdip
					--point downwards always otherwise
					steering = -$
				end
			end
			
			local steer = FixedAngle(steering*1650)
			me.boat_rollangle = $ + FixedMul(steer - $, FU/10)
		end
		if not P_PlayerInPain(p)
			me.flags = $|MF_NOSQUISH
		end
	else
		if not P_PlayerInPain(p)
			me.boat_rollangle = $ + FixedMul(0 - $, FU/2)
		end
		if me.boat_tilting
			me.flags = $ &~MF_NOSQUISH
			me.boat_tilting = false
		end
		me.boat_tilttime = 0
	end
	
	if (wastilting and not me.boat_tilting)
		me.flags = $ &~MF_NOSQUISH
		me.spritexscale,me.spriteyscale = FU,FU
		me.spriteyoffset = 0
	end
	
	--spawn the propeller
	if p.boatdriving
	or me.boat_tilting
	and p.boatvars.allowboat
	and (me.health)
	and (p.respawn.state == 0)
		if not (me.boat_prop and me.boat_prop.valid)
			me.boat_prop = P_SpawnMobjFromMobj(me,
				P_ReturnThrustX(nil,p.drawangle + ANGLE_180, FixedDiv(me.radius,me.scale) + PROPEL_OFFSET*FU),
				P_ReturnThrustY(nil,p.drawangle + ANGLE_180, FixedDiv(me.radius,me.scale) + PROPEL_OFFSET*FU),
				FixedDiv(me.height,me.scale)/2, MT_BOAT_PROP
			)
			me.boat_prop.angle = p.drawangle - ANGLE_90 --+ PROPEL_ANGDIFF
			me.boat_prop.target = me
			me.boat_prop.dispoffset = 10 + me.dispoffset
			me.boat_prop.threshold = PROPEL_EASE
			me.boat_prop.movefactor = 1
			
			do
				local over = P_SpawnMobjFromMobj(me.boat_prop,0,0,0,MT_OVERLAY)
				over.target = me.boat_prop
				over.state = S_BOAT_PROP_OV
				over.rollangle = 0
				over.dispoffset = me.boat_prop.dispoffset + 1
				--add OV_DONTROLL, which makes the overlay not copy rollangle
				over.threshold = $|(1<<3)
				me.boat_prop.overlay = over
			end
		end
	elseif (me.boat_prop and me.boat_prop.valid)
		if me.boat_prop.health
			me.boat_prop.threshold = PROPEL_EASE
			P_KillMobj(me.boat_prop)
			
			S_StopSoundByID(me,sfx_bt_st)
			S_StartSound(me,sfx_bt_de,p)
		end
	else
		me.boat_prop = nil
	end
	
	--handle boat controls
	local boatcontrols = true
	if REALLY_sinktofloor
		boatcontrols = false
	end
	
	p.boatcontrols = boatcontrols
	if p.boatdriving
	and (boatcontrols)
		p.preventfailsafe = max($,2)
		p.ignoreairtimeleniency = max($, 2)
		--if you were already slowing down, youll carry it when you exit
		p.bananadrag = min($, TR - 1)
		
		if p.inwater
		--check for time too, since we dont want to allow weird skips
		--with the water stuff, but allow tiny bobs to still count WPs
		or (me.boat_tilttime > 0 and me.boat_tilttime < TR/2)
			p.pflags = $|PF_TRUSTWAYPOINTS|PF_UPDATEMYRESPAWN
		end
		
		--yeah whatever, just drop us back in
		if p.respawn.state == RESPAWNST_DROP
			if (p.cmd.buttons & BT_ACCELERATE)
			and (p.fakedropdash >= TR/4)
				S_StartSound(me, sfx_s23c)
				--whatever
				p.spindashboost = 50
				--no dust cause we're on water? unexposed function either way
			end
			
			p.respawn.state = 0
			me.flags = $ &~MF_NOCLIPTHING
			me.colorized = false
			P_PlayerRingBurst(p,3)
			
			--no dropdash boost sorry, unexposed
			--...is what i WOULD say if i didnt rewrite
			--C code for the ease of the players
		end
		
		me.boat_tilting = true
		me.boat_fastfallhelp = nil
		me.boat_ebrakehelper = nil
		local ebrakemask = BT_FASTFALLMASK|BT_RESPAWN
		local ebraking = (p.cmd.buttons & BT_FASTFALLMASK) == BT_FASTFALLMASK
						or (p.cmd.buttons & BT_RESPAWN)
		if not ebraking
			p.fastfall = 0
		--braking on the water surface
		else
			me.boat_ebrakehelper = true
			
			local divemask = BT_DRIFT|BT_RESPAWN
			if not (p.cmd.buttons & divemask)
				if p.watertreading
					me.momz = $ / 10
				end
			elseif (p.cmd.buttons & divemask)
			and (p.drift == 0)
				me.boat_fastfallhelp = true
			end
			
			if (me.eflags & MFE_JUSTHITFLOOR)
				p.fastfall = 0
			end
			
			/*
			local mul = FU*4/5
			me.momx = FixedMul($, mul)
			me.momy = FixedMul($, mul)
			*/
		end
		
		--aiz-drift-straft? in hardcode, its aiz-drift-STRAT
		/*
		print("!",
			p.wavedash,
			p.aizdriftstraft,
			me.storedwavedash,
			p.wavedashdelay,
			p.boat_wavedelay
		)
		*/
		
		--if we stored too much sliptide for it
		--to automatically go away...
		if p.wavedash >= ((11*TICRATE/16)*9)
		and (p.aizdriftstraft == 0)
		and not (p.wavedashboost)
		and (p.drift == 0)
			--make it go away, and give back our original wavedash later
			if me.storedwavedash == nil
			or p.wavedash > me.storedwavedash
				me.storedwavedash = p.wavedash
				p.wavedash = ((11*TICRATE/16)*9) - 1
			end
		end
		if p.boat_wavedelay
		and p.wavedashdelay == 0
		and p.wavedashboost
			if me.storedwavedash
				local newwavedash = me.storedwavedash
				
				local maxzippower = 2*FU
				local minzippower = FU
				local powerspread = maxzippower - minzippower
				
				local minpenalty = 2*1 + (9-9)
				local maxpenalty = 2*9 + (9-1)
				local penaltyspread = maxpenalty - minpenalty
				local mypenalty = 2*p.kartspeed + (9 - p.kartweight)
				
				mypenalty = $ - minpenalty
				
				local powerreduc = FixedDiv(mypenalty*FU, penaltyspread*FU)
				local mypower = maxzippower - FixedMul(powerreduc, powerspread)
				local myboost = FixedInt(FixedMul(mypower, newwavedash/10 * FU))
				
				--this gives us a little more boost than normal, but thats ok
				p.wavedashboost = $ + myboost
				p.wavedashpower = min(FU, FU*newwavedash / ((11*TICRATE/16)*9))
			end
			me.storedwavedash = nil
		end
		
		do
			local friction = FU*92/100
			me.momx = FixedMul($, friction)
			me.momy = FixedMul($, friction)
			
			local travel = me.angle
			if p.drift ~= 0
				travel = $ - (ANGLE_45/5) * p.drift
				if ((p.steering - getdriftslide(p)) ~= 0 and sign(p.steering) == sign(p.drift))
					travel = $ + FixedAngle(p.steering*220) * 5
				end
			end
			
			--P_Thrust(me, travel,p.boataccel * 1390)
			local thrustspeed = FixedMul(
				K_GetKartSpeed(p,true,true) + (p.boatvars.speedstack * me.scale),
				FixedDiv(p.boataccel*FU, 50*FU)
			) / 14
			if (p.boatvars.speedmul ~= 0 and p.boatvars.speedmul ~= nil)
				thrustspeed = FixedMul($, p.boatvars.speedmul)
			end
			
			P_Thrust(me, travel, thrustspeed)
		end
		
		--charge drifts
		local oldspark = p.driftcharge
		if p.drift ~= 0
		and p.speed < me.scale
			p.driftcharge = 0
			p.pflags = $ &~PF_DRIFTINPUT
		end
		
		if p.drift ~= 0
			driftdust(p,me)
			driftdust(p,me)
			
			local dsone = sparkstage(p,1)
			local dstwo = sparkstage(p,2)
			local dsthree = sparkstage(p,3)
			local dsfour = sparkstage(p,4)
			local playsound = false
			
			--drift sliding (old)
			/*
			me.angle = $ + FixedAngle(p.drift*FU)/5
			--reapply turning since above cancels it?
			local steering = p.steering
			if steering ~= 0
			and sign(steering) ~= sign(p.drift)
				steering = $/3
			end
			me.angle = $ + FixedAngle(steering*220)
			*/
			
			local steering = p.steering - getdriftslide(p)
			local sparkcharge = 24
			if (p.pflags & PF_DRIFTINPUT)
				if p.drift >= 1
					p.drift = min($ + 1, 5)
					
					if steering > 0
						sparkcharge = $ + abs(steering)/100
					end
					if steering < 0
						sparkcharge = $ - abs(steering)/75
					end
					
				elseif p.drift <= -1
					p.drift = max($ - 1, -5)
					
					if steering < 0
						sparkcharge = $ + abs(steering)/100
					end
					if steering > 0
						sparkcharge = $ - abs(steering)/75
					end
					
				end
			end
			if (p.trickcharge)
				sparkcharge = $ + 16
			end
			
			if (p.speed <= 10*me.scale)
				sparkcharge = 0
				
				if p.driftcharge >= dsone
					p.driftcharge = -1
					playsound = true
				end
			end
			
			--hacky fix for the tridash prevention
			if p.driftcharge >= dsone
				p.lastdriftboost = 0
			end
			
			if ((p.driftcharge < dsone and p.driftcharge+sparkcharge >= dsone)
				or (p.driftcharge < dstwo and p.driftcharge+sparkcharge >= dstwo)
				or (p.driftcharge < dsthree and p.driftcharge+sparkcharge >= dsthree))
				playsound = true
			end
			
			if playsound
			--dont check for displayplayer becase who cares
				if (p.driftcharge == -1)
					S_StartSoundAtVolume(me, sfx_sploss, 192)
				else
					S_StartSoundAtVolume(me, sfx_s3ka2, 192)
				end
			end
			p.driftcharge = $ + sparkcharge
			
			if (leveltime % 50 == 0)
				S_StartSound(me, sfx_drift)
			elseif not S_SoundPlaying(me,sfx_drift)
				S_StartSound(me, sfx_drift)
			end
		else
			S_StopSoundByID(me, sfx_drift)
			
			propellsound(p,me)
		end
		if (p.pflags & PF_DRIFTEND)
			if (p.driftboost > p.lastdriftboost)
				if me.driftboost < 2
					local angle = me.angle - (ANGLE_45/5)*p.drift
					local speed = FixedHypot(me.momx,me.momy)
					me.momx = P_ReturnThrustX(nil,angle,speed)
					me.momy = P_ReturnThrustY(nil,angle,speed)
					me.driftboost = $ + 1
					
					--"[what if] null drifting jumped at none of them" -Togen
					--referring to null drifting never dolphin jumping
					if (p.cmd.forwardmove <= 0)
					--yellows and below = no jumps
					or p.lastsparks < sparkstage(p,2)
						me.momz = $ / 10
					end
				end
			end
			
			if p.driftboost
			and not REALLY_sinktofloor
				if not p.boatvars.driftdip
					me.momz = $ / 10
				elseif me.driftboost == 1
				and (p.cmd.forwardmove or p.kickstartaccel >= ACCEL_KICKSTART)
				and p.lastsparks >= sparkstage(p,2)
					local stage = 2
					if (p.lastsparks >= sparkstage(p,4))
						stage = 4
					elseif (p.lastsparks >= sparkstage(p,3))
						stage = 3
					end
					local mul = FU + (stage*FU / 3)
					
					local dipdown = -15*mul
					P_SetObjectMomZ(me,dipdown)
					
					if p.boatvars.dolphinjump
						local jump = 15*mul
						--apply gravflip later
						me.boat_jumpheight = FixedMul(jump,me.scale)
					end
				end
			end
		else
			me.driftboost = 0
		end
		animroutine(p,me)
		
		--visual bobbing
		do
			local minspeed = K_GetKartSpeed(p,false,false) * 6/5
			local factor = FU/5 + FixedDiv(
				max(minspeed - p.speed, 0), minspeed
			)
			
			if p.watertreading
				me.spriteyoffset = FixedMul(2*sin(leveltime*7*ANG1), factor)
			else
				me.spriteyoffset = $ * 7/10
			end
		end
		
		--regulate timers
		--p.ignoreairtimeleniency allows these to tick down, so...
		/*
		if p.growshrinktimer > 0
			p.growshrinktimer = $ - 1
		end
		if p.invincibilitytimer
			p.invincibilitytimer = $ - 1
		end
		*/
		if p.spinouttimer
		and (not p.sneakertimer)
			p.spinouttimer = $ - 1
			if not (leveltime % 6)
				S_StartSound(me,sfx_cdfm70)
			end
		end
		if p.wavedashboost
			p.wavedashboost = $ - 1
		end
		if p.rocketsneakertimer
			p.rocketsneakertimer = $ - 1
		end
		/*
		--Unexposed in 2.3
		if p.startboost > 0
			p.startboost = $ - 1
		end
		*/
		if p.trickcharge
			p.trickcharge = $ - 1
			if (p.drift ~= 0)
				p.trickcharge = max($, 1)
			end
			if (gametyperules & GTR_SPHERES) and (leveltime % 10 == 0)
				p.spheres = $ + 1
			end
		end
		p.airtime = 0
		
		--handle some items here
		if canuseitem(p)
			local attackisdown = (p.cmd.buttons & BT_ATTACK) and not ((p.oldcmd.buttons & BT_ATTACK) and (p.respawn.state == 0))
			local holdingitem = p.itemflags & (IF_ITEMOUT|IF_EGGMANOUT)
			--boo is easier to spell than "hyudoro"
			local noboo = (p.stealingtimer == 0)
			
			if (p.itemflags & IF_USERINGS)
			else
				if p.eggmanexplode
				elseif p.itemflags & IF_EGGMANOUT
				elseif p.rocketsneakertimer > 1
					if attackisdown and not holdingitem and noboo
						K_DoSneaker(p, 2)
						K_PlayBoostTaunt(me)
						if (p.rocketsneakertimer <= 3*TR)
							p.rocketsneakertimer = 1
						else
							p.rocketsneakertimer = $ - 3*TR
						end
						
					end
				elseif (p.itemammount == 0)
				else
					--switch itemtype
					if p.itemtype == KITEM_SNEAKER
						if attackisdown and not holdingitem and noboo
							K_DoSneaker(p, 1)
							K_PlayBoostTaunt(me)
							p.itemamount = $ - 1
						end
					elseif p.itemtype == KITEM_ROCKETSNEAKER
						if (attackisdown and not holdingitem and noboo
						and p.rocketsneakertimer == 0)
							K_PlayBoostTaunt(me)
							S_StartSound(me,sfx_s3k3a)
							
							p.rocketsneakertimer = (8*TR)*3
							p.itemamount = $ - 1
							--hoping this is handled internally
							--K_UpdateHnextList
							
							local loop = 0
							local prev = me
							for i = 0,1
								local shoe = P_SpawnMobjFromMobj(me,0,0,0,MT_ROCKETSNEAKER)
								K_MatchGenericExtraFlags(shoe,me)
								shoe.flags = $|MF_NOCLIPTHING
								shoe.angle = me.angle
								shoe.threshold = 10
								shoe.movecount = loop%2
								shoe.movedir = loop + 1
								shoe.lastlook = shoe.movedir
								
								shoe.target = me
								shoe.hprev = prev
								prev.hnext = shoe
								
								prev = shoe
								loop = $ + 1
							end
						end
					--maybe its best you cant use this here...
					/*
					elseif p.itemtype == KITEM_POGOSPRING
						if (attackisdown and not holdingitem and noboo and p.trickpanel == 0)
							K_PlayBoostTaunt(me)
							P_SpawnMobjFromMobj(me, 0,0,0, MT_POGOSPRING)
							p.itemamount = $ - 1
						end
					*/
					end
				end
			end
		end
	--uhhh stupid workaround
	elseif p.boatdriving
	and REALLY_sinktofloor
		animroutine(p,me)
		propellsound(p,me)
		
		p.bananadrag = min($, TR - 1)
	end
	
	if me.boat_bubblefx
		if (me.eflags & MFE_TOUCHWATER)
			local spawnrange = FixedDiv(me.radius,me.scale) >> FRACBITS
			local spawnx = P_RandomRange(-spawnrange,spawnrange) << FRACBITS
			local spawny = P_RandomRange(-spawnrange,spawnrange) << FRACBITS
			local speedrange = 2
			local dust = P_SpawnMobjFromMobj(me,spawnx,spawny,0,MT_DRIFTDUST)
			dust.momx = FixedMul(me.momx + (P_RandomRange(-speedrange,speedrange)*me.scale), FU*3/4)
			dust.momy = FixedMul(me.momy + (P_RandomRange(-speedrange,speedrange)*me.scale), FU*3/4)
			dust.momz = P_MobjFlip(me) * P_RandomRange(1,4)*me.scale
			P_SetScale(dust, me.scale/2)
			dust.destscale = me.scale*3
			dust.scalespeed = me.scale/12
			dust.state = S_SPINDUST_BUBBLE1
		end
		me.boat_bubblefx = $ - 1
	elseif me.boat_bubblefx == nil
		me.boat_bubblefx = 0
	end
	p.cmd.buttons = sortofrealbuttons
end)

addHook("MapChange",do
	for p in players.iterate
		p.boatvars = nil
		p.inwater = false
		p.boatdriving = false
	end
end)

addHook("PostThinkFrame",do
	if not (mapheaderinfo[gamemap] and mapheaderinfo[gamemap].boat ~= nil) then return end
	for p in players.iterate
		local me = p.mo
		if not (me and me.valid) then continue end
		
		if me.boat_rollangle ~= nil
		and me.boat_rollangle ~= 0
		and not (p.tumblebounces)
			local viewang = R_PointToAngle(me.x,me.y)
			local angledelta = me.angle - viewang
			local rolladd = FixedMul(me.boat_rollangle,sin(abs(angledelta))) +
							FixedMul(me.boat_rollangle,cos(angledelta))
			
			me.rollangle = rolladd
		end
		
		if p.boatdriving
			animroutine(p,me)
			--cant set p->outrun here since its Unexposed!! Yay!!!
			--so try not to use charger panels :p
		end
		
		if me.boat_transform ~= nil
			me.boat_transform = $ - 1
			
			if (me.boat_transform & 1)
				me.colorized = true
				me.lightlevel = 255
				me.frame = $|FF_FULLBRIGHT
			else
				me.colorized = false
			end
			
			if not me.boat_transform
				me.colorized = false
				me.boat_transform = nil
			end
			
		end
	end
end)
addHook("PreThinkFrame",do for p in players.iterate
	p.lastsparks = p.driftcharge
	p.lastdriftboost = p.driftboost
	p.boat_wavedelay = p.wavedashdelay
end; end)

local function setSpriteAndFrame(mo, overlay)
	local finalsprite = SPR_BT__
	--A == 0, which is a falsy value so it fails the tenary
	local finalframe = (overlay) and B or A
	local prefix = (overlay) and "boat_propol_" or "boat_prop_"
	
	local spritedata = getattrib(prefix.."sprite", "SPR_BT__", true)
	spritedata = $:upper()
	if spritedata:sub(1,4) ~= "SPR_"
		spritedata = "SPR_"..$
	end
	if (pcall(do return _G[spritedata] end))
		finalsprite = _G[spritedata]
	end
	
	local standardframe = "A"
	--always assume frame B for standard propeller sprite,
	--otherwise, A so sprites dont break
	if (overlay and finalsprite == SPR_BT__)
		standardframe = "B"
	end
	
	local framedata = getattrib(prefix.."frame", standardframe, true)
	framedata = $:upper()
	
	--using frame letters? (ex. A, B, C, ...)
	if tonumber(framedata) == nil
		if (pcall(do return _G[framedata] end))
			finalframe = _G[framedata]
		end
	else
		finalframe = tonumber(framedata)
	end
	
	finalframe = $ & FF_FRAMEMASK
	
	return finalsprite, finalframe
end

addHook("MobjThinker",function(mo)
	if not (mo and mo.valid) then return end
	local me = mo.target
	if not (me and me.valid)
		P_RemoveMobj(mo)
		return
	end
	local p = me.player
	
	local thrustangle = p.drawangle - PROPEL_ANGDIFF*p.drift
	P_MoveOrigin(mo,
		me.x + P_ReturnThrustX(nil,thrustangle + ANGLE_180, me.radius + PROPEL_OFFSET*me.scale),
		me.y + P_ReturnThrustY(nil,thrustangle + ANGLE_180, me.radius + PROPEL_OFFSET*me.scale),
		me.z + me.height/2
	)
	if P_MobjFlip(me) == -1
		mo.z = $ - mo.height + me.height/2
		mo.eflags = $|MFE_VERTICALFLIP
	else
		mo.eflags = $ &~MFE_VERTICALFLIP
	end
	local sign = 1
	if (p.cmd.forwardmove < 0)
	and (p.speed > 2 * me.scale)
		local ang1 = me.angle
		local ang2 = R_PointToAngle2(0,0, me.momx,me.momy)
		local adiff = FixedAngle(
			AngleFixed(ang1) - AngleFixed(ang2)
		)
		if AngleFixed(adiff) > 180*FU
			adiff = InvAngle($)
		end
		
		--propeller spins backwards when you go backwards
		if AngleFixed(adiff) >= 60*FU
			sign = -1
		end
	end
	
	mo.rollangle = $ + FixedAngle(5*FU + 35*FixedDiv(p.speed, K_GetKartSpeed(p,false,false)*2)) * sign
	mo.angle = thrustangle - ANGLE_90 --+ (PROPEL_ANGDIFF * mo.movefactor)
	mo.destscale = me.scale
	mo.scalespeed = mo.destscale + 1
	
	mo.spriteyoffset = me.spriteyoffset
	--FF_FULLBRIGHT removes the sector colormap effect so uhh
	mo.lightlevel = 255
	if me.boat_transform ~= nil
		mo.color = me.color
		mo.colorized = (me.boat_transform & 1) and true or false
	else
		mo.colorized = false
	end
	
	do
		local newsprite,newframe = setSpriteAndFrame(mo,false)
		mo.frame = A
		
		mo.sprite = newsprite
		mo.frame = newframe|FF_PAPERSPRITE
	end
	if mo.overlay and mo.overlay.valid
		mo.overlay.color = mo.color
		mo.overlay.colorized = mo.colorized
		mo.overlay.spriteyoffset = mo.spriteyoffset
		mo.overlay.angle = thrustangle - ANGLE_90
		mo.overlay.lightlevel = 255
		
		local newsprite,newframe = setSpriteAndFrame(mo,true)
		mo.overlay.frame = A
		
		mo.overlay.sprite = newsprite
		mo.overlay.frame = newframe|FF_PAPERSPRITE
	end
	
	if mo.threshold ~= 0
		local threshold = mo.threshold
		local func = ease.inoutback
		if (mo.health)
			threshold = PROPEL_EASE - $
		end
		
		local back = FU*3/4
		local frac = (FU/PROPEL_EASE)*threshold
		local xscale = ease.inoutback(
			frac,
			2*FU, FU, back
		)
		local yscale
		if frac <= FU/2
			yscale = ease.insine(
				frac,
				0, 2*FU
			)
		else
			yscale = ease.outsine(
				frac,
				4*FU, FU
			)
		end
		
		mo.spritexscale = max(xscale, FU/64)
		mo.spriteyscale = max(yscale, FU/64)
		
		if mo.threshold > 0
			mo.threshold = $ - 1
		elseif mo.threshold < 0
			mo.threshold = $ + 1
		end
		
		if not (mo.health)
		and (mo.threshold == 0)
			P_RemoveMobj(mo)
		end
	end
end,MT_BOAT_PROP)

/*
struct activator_t
{
	mobj_t *mo;
	line_t *line;
	UINT8 side;
	sector_t *sector;
	polyobj_t *po;
	boolean fromLineSpecial; // Backwards compat for ACS
};
*/

/*
	arg 1: driftdip:		(3-2-1-0) = (MapDefault-Yes-No-LeaveAsIs)
	arg 2: allowboating:	(3-2-1-0) = (MapDefault-Yes-No-LeaveAsIs)
	stringarg2: speedmul:	any decimal number
	arg 3: dolphinjumps:	(3-2-1-0) = (MapDefault-Yes-No-LeaveAsIs)
	arg 4: speedstack:		any integer number
*/
local setpvars_amount = 4
local setpvars_attribs = {
	--	    boatvars index,	 mapheader key
	[1] = {"driftdip",		"boat_driftdip"},
	[2] = {"allowboat",		"boat_boatonbydefault"},
	[3] = {"dolphinjump",	"boat_dolphinjump"},
	[4] = {"speedstack",	"boat_speedincrease"},
}
addHook("SpecialExecute",function(activator, args,stringargs)
	local mo = activator.mo
	
	if not (mo and mo.valid) then return end
	local p = mo.player
	if not (p and p.valid) then return end
	if not (p.boatvars) then return end
	
	for i = 1,setpvars_amount
		local attrib = setpvars_attribs[i]
		
		-- "speedmul"
		if stringargs[1] ~= nil
			if i == 1
				p.boatvars.speedmul = L_DecimalFixed(stringargs[1])
			end
		end
		
		if args[i] == 0
			-- "speedstack"
			if i == 4
				p.boatvars[attrib[1]] = 0
			end
			continue
		end
		
		-- "speedstack"
		if i == 4
			p.boatvars[attrib[1]] = args[i]
			continue
		end
		
		if args[i] == 3
			p.boatvars[attrib[1]] = getattrib(attrib[2], boatvar_defaults[i])
		else
			p.boatvars[attrib[1]] = args[i] == 2
		end
	end
end,"BOAT_SETPVARS")

--Bot helper
addHook("SpecialExecute",function(activator, args,stringargs)
	local mo = activator.mo
	
	if not (mo and mo.valid) then return end
	local p = mo.player
	if not (p and p.valid) then return end
	if not (p.boatvars) then return end
	if not (p.boatdriving) then return end
	
	if (mo.boat_jumpheight ~= nil) then return end
	
	--argument 2 must be set to make this work for human players too
	if (args[2] == 0 and not p.bot) then return end
	
	--argument 1 is equivialent to the mini turbo level for
	--calculating the heights
	
	--allow for stage 1 boosts
	local stage = min(max(args[1], 1), 4)
	local mul = FU + (stage*FU / 3)
	
	local dipdown = -15*mul
	P_SetObjectMomZ(mo,dipdown)
	
	local jump = 15*mul
	mo.boat_jumpheight = FixedMul(jump,mo.scale)
end,"BOAT_DODOLPHIN")

-- items.lua
--handles item behavior/interactions with the boat physics
local MAPBLOCKUNITS = 128
local MAPBLOCKSIZE = MAPBLOCKUNITS*FU
local function randomitemscale(oldscale)
	local newscale = oldscale * 3
	local maxscale = FixedDiv(MAPBLOCKSIZE, mobjinfo[MT_RANDOMITEM].radius)
	return min(newscale, maxscale)
end

local spawninglist = {}
local thinkerlist = {}
local chargefalllist = {}

local function trapitem_spawn(item)
	if not (mapheaderinfo[gamemap] and mapheaderinfo[gamemap].boat ~= nil) then return end
	
	table.insert(spawninglist, item)
end

addHook("MobjSpawn",trapitem_spawn,MT_BANANA)
addHook("MobjSpawn",trapitem_spawn,MT_EGGMANITEM)
addHook("MobjSpawn",trapitem_spawn,MT_ORBINAUT) --special
--jawz should be fine, it automatically waterruns anyways
----FIXME: later
--addHook("MobjSpawn",trapitem_spawn,MT_SSMINE_SHIELD)
----doesnt set water surfaces
--addHook("MobjSpawn",trapitem_spawn,MT_LANDMINE)
----doesnt set water surfaces
--addHook("MobjSpawn",trapitem_spawn,MT_DROPTARGET)
addHook("MobjSpawn",trapitem_spawn,MT_GACHABOM)

addHook("MobjSpawn",trapitem_spawn,MT_CHARGEFALL) --hacky

addHook("NetVars", function(n)
	thinkerlist = n($)
	spawninglist = n($)
	chargefalllist = n($)
end)

addHook("PreThinkFrame",do
	--handle spawning here, since it needs to be delayed in order
	--to get the item's target
	for k,item in ipairs(spawninglist)
		if not (item and item.valid)
			table.remove(spawninglist, k)
			continue
		end
		
		if not ((item.target and item.target.valid)
		and (item.target.player and item.target.player.valid))
			return
		end
		
		local me = item.target
		local p = me.player
		
		if (p.boatdriving)
		or (me.boat_tilting)
			table.insert(
				(item.type == MT_CHARGEFALL) and chargefalllist or thinkerlist,
				item
			)
		end
		
		table.remove(spawninglist, k)
		continue
	end

	--then we can iterate through the items
	for k,item in ipairs(thinkerlist)
		if not (item and item.valid)
		or not item.health
			table.remove(thinkerlist, k)
			continue
		end
		
		if (item.type == MT_LANDMINE)
		and item.threshold
			continue
		end
		
		local origin = (item.target and item.target.valid) and item.target or item
		local wasinwater = item.inwater
		
		local gravflip = P_MobjFlip(item)
		local sink = (item.height / 5)
		local z = item.z
		local water_top = item.watertop - sink
		do	
			if (gravflip == -1)
				water_top = item.waterbottom + sink
				z = item.z+item.height
			end
			
			/*
			print(string.format("land %f\n%f\n%s\n%s\n%f",
				z, water_top,
				tostring(water_top ~= item.z - 1000*FU),
				tostring(z < water_top),
				item.height
			))
			*/
			if (water_top ~= item.z - 1000*FU)
			and (z < water_top)
				item.inwater = true
				
				if not wasinwater
					if not (item.type == MT_ORBINAUT
					or item.type == MT_GACHABOM)
						item.momx = $ / 5
						item.momy = $ / 5
					end
					item.momz = $ / 5
					
					if item.bobs == nil
						item.bobs = 0
					end
					item.bobs = $ + 1
				end
			end
		end
		
		if item.inwater
			if (abs(water_top - z) < 3*item.scale)
			and abs(item.momz) <= 5*item.scale
				item.momz = $*2/3
				
				if abs(item.momz) <= 3*item.scale
					item.momz = $/3
				end
				
			--buoyant
			else
				item.flags = $|MF_NOGRAVITY
				local floating = (origin.scale*3/2)*gravflip
				local diff = (water_top - z) * gravflip
				if diff < 0
					floating = -$
				end
				
				item.momz = $ + floating --FixedDiv(abs(diff/100), abs(floating))
			end
			item.waterskip = max($,3)
			
			if (item.type == MT_BANANA)
			or (item.type == MT_EGGMANITEM)
			or (item.type == MT_SSMINE)
				item.extravalue2 = 0
				
				if item.bobs
					item.momz = $ / item.bobs
				end
				item.momx = $ / 2
				item.momy = $ / 2
				
				if (item.type == MT_BANANA)
				or (item.type == MT_EGGMANITEM)
					if abs(water_top - z) < 10*item.scale
						item.momz = 0
					end
					if (item.momz*gravflip <= -10*origin.scale)
						item.momz = -10*origin.scale
					end
					
					if item.health > 1
						S_StartSound(item, item.info.activesound)
						item.health = 1
						item.momx,item.momy = 0,0
						
						if (item.type == MT_EGGMANITEM)
							--love it
							item.destscale = randomitemscale(item.scale)
						end
					end
				end
			end
		end
		
		if (wasinwater and not item.inwater)
			--item.flags = $ &~MF_NOGRAVITY
			
			item.momz = 0
			item.momx = $ / 5
			item.momy = $ / 5
		end
		
	end
end)

-- .
addHook("PostThinkFrame", do
	for k,item in ipairs(chargefalllist)
		if not (item and item.valid)
		or not item.health
			table.remove(chargefalllist, k)
			continue
		end
		
		-- Lol!
		item.renderflags = $ &~RF_DONTDRAW
	end
end)

--lul
addHook("MobjThinker",function(stumble)
	local me = stumble.target
	if not (me and me.valid) then return end
	local p = me.player
	if not (p and p.valid) then return end
	
	--we wont stumble in this condition
	if me.boat_tilting
		stumble.renderflags = $|RF_DONTDRAW
	end
end,MT_SMOOTHLANDING)

--debug.lua
if (BOAT_DEBUG ~= nil)
addHook("HUD",function(v, p)
	local x = 5
	local y = 90
	local flags = V_SNAPTOLEFT
	local strtype = "thin"
	
	if not (p.mo and p.mo.valid) then return end
	
	y = $ - 30
	v.drawString(x,y,   "\x84MF_NOSQUISH\x80 : "..tostring(p.mo.flags & MF_NOSQUISH == MF_NOSQUISH), flags, strtype)
	v.drawString(x,y+10,"\x84p.aizdriftstraft\x80 : "..(p.aizdriftstraft), flags, strtype)
	v.drawString(x,y+20,"\x84p.drift\x80 : "..(p.drift), flags, strtype)
	y = $ + 30
	
	if (p.boatvars == nil)
		v.drawString(x,y, "No p.boatvars", V_GRAYMAP|flags, strtype)
		return
	end
	
	v.drawString(x,y, "p.boatvars = {", V_YELLOWMAP|flags, strtype)
	x = $ + 10
	y = $ + 10
	
	for key, value in pairs(p.boatvars)
		if type(value) == "boolean"
			value = "\x84" .. tostring($)
		elseif tostring(key) == "speedmul"
			value = string.format("%f", tonumber(value))
		end
		
		v.drawString(x,y,
			tostring(key) .." = ".. tostring(value),
		flags, strtype)
		y = $ + 10
	end
	x = $ - 10
	v.drawString(x,y, "}", V_YELLOWMAP|flags, strtype)
	
	x = 180
	y = 5
	flags = V_SNAPTORIGHT|V_SNAPTOTOP
	for play in players.iterate
		v.drawString(x,y,
			string.format("\x84[%.2d] - %s%s\x80->steering = \x82%d",#play, (play == p and "\x82" or ""), play.name, play.steering or 0),
			flags, strtype
		)
		y = $ + 10
	end
end,"game")

/*
#define DMG_NORMAL  0x00
#define DMG_WIPEOUT 0x01 // Normal, but with extra flashy effects
#define DMG_EXPLODE 0x02
#define DMG_TUMBLE  0x03
#define DMG_STING   0x04
#define DMG_KARMA   0x05 // Karma Bomb explosion -- works like DMG_EXPLODE, but steals half of their bumpers & deletes the rest
#define DMG_VOLTAGE 0x06
#define DMG_STUMBLE 0x07 // Does not award points in Battle
#define DMG_WHUMBLE 0x08 // <-- But this one DOES!
//// Death types - cannot be combined with damage types
#define DMG_INSTAKILL  0x80
#define DMG_DEATHPIT   0x81
#define DMG_CRUSHED    0x82
#define DMG_SPECTATOR  0x83
#define DMG_TIMEOVER   0x84
// Masks
#define DMG_WOMBO		 0x10 // Flag - setting this flag allows objects to damage you if you're already in spinout. The effect is reversed on objects with MF_MISSILE (setting it prevents them from comboing in spinout)
#define DMG_STEAL        0x20 // Flag - can steal bumpers, will only deal damage to players, and will not deal damage outside Battle Mode.
#define DMG_CANTHURTSELF 0x40 // Flag - cannot hurt your self or your team
#define DMG_DEATHMASK    DMG_INSTAKILL // if bit 7 is set, this is a death type instead of a damage type
#define DMG_TYPEMASK     0x0F // Get type without any flags
*/
COM_AddCommand("damageme",function(p, enum)
	local me = p.mo
	if not (me and me.valid) then return end
	if enum == nil then return end
	
	local todo = string.upper(enum)
	local realnum = _G["DMG_"..todo] or nil
	if realnum ~= nil
		P_DamageMobj(me, nil,nil,1, realnum)
	else
		CONS_Printf(p,"Flag invalid ("..todo..")")
	end
end,COM_ADMIN)

end --if (BOAT_DEBUG ~= nil)
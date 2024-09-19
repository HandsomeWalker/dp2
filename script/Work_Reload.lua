local luv = require("luv")
local world = require("df.game.mgr.world")

local item_handler = { }

--------------------------------------------------------------------------特殊功能开头----------------------------------------------------------------------------

-------------------------------------------------------------------------玩家上下线通知-----------------------------------------------------------------------------
--记录在线情况
local online = {}
--玩家登录游戏hook
local function onLogin(_user)
    local user = game.fac.user(_user)
    local uid = user:GetAccId()

    online[uid] = true

    sendPacketMessage(string.format("玩家【%s】上线了", user:GetCharacName()), 14)
    logger.info(string.format("玩家【%s】上线了", user:GetCharacName()))
    local logFile = io.open("/dp2/script/rizhi.log", "a")  
    if logFile then
        local logMsg = string.format("%s	%d	%s	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), "上线了")
        logFile:write(logMsg)  
        logFile:close()  
    end
end
dpx.hook(game.HookType.Reach_GameWord, onLogin)
--玩家退出游戏hook
local function onLogout(_user)
    local user = game.fac.user(_user)
    local uid = user:GetAccId()

    online[uid] = nil

    sendPacketMessage(string.format("玩家【%s】下线了", user:GetCharacName()), 14)
    logger.info(string.format("玩家【%s】下线了", user:GetCharacName()))
    local logFile = io.open("/dp2/script/rizhi.log", "a")  
    if logFile then
        local logMsg = string.format("%s	%d	%s	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), "下线了")
        logFile:write(logMsg)  
        logFile:close()  
    end
end
dpx.hook(game.HookType.Leave_GameWord, onLogout)

--------------------------------------------------------------------------发送信息设定？---------------------------------------------------------------------------
function sendPacketMessage(message, type)
    --遍历在线玩家
    for k, v in pairs(online) do
        local _uid = k
        if _uid ~= nil and online[_uid] then
            local _ptr = world.FindUserByAcc(_uid)
            local _user = game.fac.user(_ptr)
            -- 在线玩家发送消息
            _user:SendNotiPacketMessage(message, type)
        end
    end
end

--------------------------------------------------------------------------经验副本----------------------------------------------------------------------------
--在副本5000中，每分钟获得1%经验值，60代币，直到90级
--启动时就设置一个每秒的定时器
local paodianTimer = luv.new_timer()

local function addExp(uid)
    local ptr = world.FindUserByAcc(uid)
    if not ptr then
        return
    end
    local user = game.fac.user(ptr)
    if user:GetState() < 3 then
        return
    end
    if user:GetCharacLevel() >= 90 then
        return
    end
    local party = user:GetParty()
    if not party then
        return
    end
    local dungeon = party:GetDungeon()
    if not dungeon then
        return
    end

    local dungeonId = dungeon:GetIndex()
    if dungeonId == 5000 then
        user:AddCharacExpPercent(0.01)
		user:ChargeCeraPoint(60)
		user:SendNotiPacketMessage("经验值增加：1%  代币增加：60", 14)
    end
end

local function onExpTimer()
    for k, v in pairs(online) do
        local uid = k
        addExp(uid)
    end
end
paodianTimer:start(60000, 60000, onExpTimer)--1分钟后开始执行，随后每1分钟执行一次

--------------------------------------------------------------------------翻牌回城----------------------------------------------------------------------------
local function finishBackHome(fnext, type, _party, param)
    if type == game.GameEventType.PARTY_DUNGEON_FINISH then
        fnext()
        local party = game.fac.party(_party)
        party:ReturnToVillage()
    end
    return fnext()
end
--------------------------------------------------------------------------持物进图----------------------------------------------------------------------------
--背包中有80206，才能进入5000副本
local function myGameEvent(fnext, type, _party, param)
    if type == game.GameEventType.PARTY_DUNGEON_START then
        ---@type integer
        local dungeonId = param.id
        if dungeonId == 5000 then
            local party = game.fac.party(_party)
            local isAllow = true

            party:ForEachMember(function(user, pos)
                local inven = user:GetCurCharacInvenR()

                if inven:CheckItemExist(80206) < 0 then
				    user:SendNotiPacketMessage("持有特殊凭证才能进入此副本！", 14)
                    isAllow = false
                    return false
                end

                return true
            end)

            if not isAllow then
                return 14 -- err code
            end
        end
    end

    return fnext()
end


--------------------------------------------------------------------------道具使用逻辑----------------------------------------------------------------------------
local my_useitem2 = function(_user, item_id)
    local user = game.fac.user(_user)
    local handler = item_handler[item_id]
    if handler then
        handler(user, item_id)
        logger.info("[useitem] acc: %d chr: %d item_id: %d", user:GetAccId(), user:GetCharacNo(), item_id)
    end
end


--------------------------------------------------------------------------等级控制掉落----------------------------------------------------------------------------
--角色等级大于副本等级20级且背包内没有【80207】道具时，刷图不掉落
local my_drop_item = function(_party, monster_id)
    local party = game.fac.party(_party)
    local dungeon = party:GetDungeon()
    local dungeonLevel = dungeon:GetStandardLevel()
    local isDropItem = true

    party:ForEachMember(function(user, pos)
        local lv = user:GetCharacLevel()
		local inven = user:GetCurCharacInvenR()

        if lv - dungeonLevel > 20 and inven:CheckItemExist(80207) < 1 then
		    user:SendNotiPacketMessage("此副本等级过低，掉落物品已被系统收回！", 14)
            isDropItem = false
            return false
        end

        return true
    end)

    return isDropItem
end

--------------------------------------------------------------------------强化增幅必成----------------------------------------------------------------------------
--强化/增幅失败时，减少一个材料【80208】并进行一次判定，通过则强制改为强化/增幅成功，未通过或无材料则仍然失败
local function MyUpgrade(fnext, _user, iitem)
    -- 先调用一下原函数
    local ok = fnext()
	local user = game.fac.user(_user)
    -- 失败了吗
    if not ok then
		local inven = user:GetCurCharacInvenR()
	    if inven:CheckItemExist(802108) < 1 then
			user:SendNotiPacketMessage("未检测到精灵的祝福，维持失败结果。", 14)
		else
		
			local list1 = {80208} -- 可以回收的id
    		local to_recycle = {} -- 待回收列表
   			 math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
   			for i = 105, 152, 1 do --遍历背包并减少【list1】中的道具的数量
       			local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
       			if info then
          			for _, _equip in ipairs(list1) do
           			    if info.id == _equip then
               			    table.insert(to_recycle, i)

                            dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
                            break
                        end
					end
				end
			end

		 	local q = math.random(1, 5) --在1-5中随机一个值
			if q < 5 then --若随机的值小于5，强化/增幅任然失败
			    user:SendNotiPacketMessage("精灵的祝福失败，维持失败结果。", 14)
				local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		 	    if logFile then
         	    local logMsg = string.format("%s	%d	%s	精灵祝福失败	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), iitem:has_amplify_ability() and "增幅" or "强化")
         	    logFile:write(logMsg)  
          	    logFile:close()  
          	    end	
			else --否则失败结果强制改为成功
         	    iitem:inc_upgrade()
         	    ok = true
		 	    sendPacketMessage(string.format("—————————精灵的祝福—————————\n 玩家【%s】 在精灵的祝福下 %s成功啦!", user:GetCharacName(), iitem:has_amplify_ability() and "增幅" or "强化"), 15)
		 	    local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		 	        if logFile then
         	        local logMsg = string.format("%s	%d	%s	精灵祝福成功	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), iitem:has_amplify_ability() and "增幅" or "强化")
         	        logFile:write(logMsg)  
          	        logFile:close()  
          	        end	
         	end
        end
    end

    return ok
end

--------------------------------------------------------------------------特殊功能结尾----------------------------------------------------------------------------


----------------------------------------------------------------------------指令开头----------------------------------------------------------------------------
local lastSignInTime = {}  
local on_input = function(fnext, _user, input)
    local user = game.fac.user(_user)
    logger.info("INPUT|%d|%s|%s", user:GetAccId(), user:GetCharacName(), input)
--最后的数字代表文本颜色
-- 0  系统消息
-- 1  悄悄话 青色
-- 2  队伍   蓝色
-- 3  普通   白色
-- 4  未知
-- 5  普通   白色
-- 6  公会   红色
-- 7  普通   青色
-- 8  师徒   黄色
-- 9  队伍   蓝色
--10  喇叭   绿色  GM消息 异常
--11  喇叭   黄色  频道标志
--12  喇叭   黄色  频道标志
--13  喇叭   黄色  频道标志
--14  喇叭   绿色  频道标志
--15  喇叭   黄色  频道标志
--16  系统消息     16-20都是如此 
--user:SendNotiPacketMessage("——————————指令结束——————————", 14)最多一次性显示160条，显示内容4.3行左右，大概85个汉字
----------------------------------------------------------------------------以下是菜单----------------------------------------------------------------------------
    if input == "//指令" then
        user:SendNotiPacketMessage("——————————指令开始——————————", 14)
        user:SendNotiPacketMessage("功能：个人信息  指令：//myinfo", 14)
        user:SendNotiPacketMessage("功能：每日签到  指令：//qd", 14)
		user:SendNotiPacketMessage("功能：充值相关  指令：//cz", 14)
		user:SendNotiPacketMessage("功能：查询物品  指令：//view", 14)
        user:SendNotiPacketMessage("功能：发送物品  指令：//send", 14)
		user:SendNotiPacketMessage("功能：设置等级  指令：//setlv", 14)
		user:SendNotiPacketMessage("功能：接取任务  指令：//getq", 14)
		user:SendNotiPacketMessage("功能：清理任务  指令：//clearq", 14)
        user:SendNotiPacketMessage("功能：职业相关  指令：//zhiye", 14)
        user:SendNotiPacketMessage("功能：决斗信息  指令：//pvp", 14)
		user:SendNotiPacketMessage("功能：清理背包  指令：//clearp", 14)
		user:SendNotiPacketMessage("功能：装备跨界  指令：//moveequ", 14)
		user:SendNotiPacketMessage("功能：装备继承  指令：//trans", 14)
		user:SendNotiPacketMessage("功能：重置异界  指令：//e23rs", 14)
		user:SendNotiPacketMessage("功能：城镇坐标  指令：//postwn", 14)
		user:SendNotiPacketMessage("功能：设置虚弱  指令：//weak", 14)
		user:SendNotiPacketMessage("功能：复杂指令  指令：//set", 14)
		user:SendNotiPacketMessage("功能：分解装备【诺顿】  指令：//fj1", 6)
		user:SendNotiPacketMessage("功能：分解装备【分解机】  指令：//fj2", 6)
        user:SendNotiPacketMessage("——————————指令结束——————————", 14)

    elseif input == "//myinfo" then
	    user:SendNotiPacketMessage(string.format("——————————个人信息——————————\n 账号编号： %s\n 角色编号： %s\n 角色姓名： %s\n 角色等级： %s\n 职业编号： %s\n 转职编号： %s\n 副职编号： %s\n 已用疲劳： %s", user:GetAccId(), user:GetCharacNo(), user:GetCharacName(), user:GetCharacLevel(), user:GetCharacJob(), user:GetCharacGrowType(), user:GetCurCharacExpertJobType(), user:GetFatigue()), 14)

    elseif input == "//set" then
        user:SendNotiPacketMessage("—------------修改数据库-------------\n  通过sh脚本，修改数据库相关数值\n  部分修改只对离线玩家生效，较复杂，慎用", 14)
        user:SendNotiPacketMessage("//set1X+Y=Z 更改表【charac_info】\nX为数据库表中列名，Y为角色编号，Z为数值\n指令：//set1  查看具体信息", 14)
        user:SendNotiPacketMessage("//set2X+Y=Z 更改表【charac_stat】\nX为数据库表中列名，Y为角色编号，Z为数值\n指令：//set2  查看具体信息", 14)
        user:SendNotiPacketMessage("//set3X     更改表【member_dungeon】\n开启账号编号X的所有副本难度，使用指令前该账号需通关一次任意副本", 14)
        user:SendNotiPacketMessage("//set4X=Y   更改表【charac_tower_despair】\nX为角色编号，Y为已挑战的绝望之塔层数，使用指令前该角色需通关任意一层", 14)

--//set1说明
    elseif input == "//set1" then
        user:SendNotiPacketMessage("—--------【charac_info】---------", 14)
        user:SendNotiPacketMessage("job         角色职业 0-10", 14)
        user:SendNotiPacketMessage("grow_type   转职职业  0-5", 14)
        user:SendNotiPacketMessage("expert_job   副职业 0-3", 14)
        user:SendNotiPacketMessage("HP           未知", 14)
        user:SendNotiPacketMessage("maxHP        未知", 14)
        user:SendNotiPacketMessage("maxMP        未知", 14)
        user:SendNotiPacketMessage("phy_attack   未知", 14)
        user:SendNotiPacketMessage("phy_defense   未知", 14)
        user:SendNotiPacketMessage("mag_attack   未知", 14)
        user:SendNotiPacketMessage("mag_defense   未知", 14)
        user:SendNotiPacketMessage("hp_regen", 14)
        user:SendNotiPacketMessage("mp_regen", 14)
        user:SendNotiPacketMessage("move_speed", 14)
        user:SendNotiPacketMessage("attack_speed", 14)
        user:SendNotiPacketMessage("cast_speed", 14)
        user:SendNotiPacketMessage("hit_recovery", 14)
        user:SendNotiPacketMessage("jump", 14)
        user:SendNotiPacketMessage("charac_weight", 14)

--更改指定玩家的在表【charac_info】中的信息
	elseif string.match(input, "//set1") and string.len(input) > 6 then

		if string.match(input, "+") and string.match(input, "=") then
			local a = string.find(input, "+")
			local b = string.find(input, "=")
			local x = string.sub(input, 7, a-1)
			local y = string.sub(input, a+1, b-1)
			local z = tonumber(string.sub(input, b+1))

        dpx.sqlexec(game.DBType.taiwan_cain, "update charac_info set " .. x .. "=" .. z .. " where charac_no=" .. y .. "")

        user:SendNotiPacketMessage(string.format("已更改 玩家【%s】 表【charac_info】 列【%s】 值【%s】 ", y, x, z), 14)
        local logFile = io.open("/dp2/script/rizhi.log", "a")  
            if logFile then
                local logMsg = string.format("%s	%d	%s	set	玩家%s	表charac_info 列%s 值%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), y, x, z)
                logFile:write(logMsg)  
                logFile:close()  
            end
		
		end

--//set2说明
    elseif input == "//set2" then
        user:SendNotiPacketMessage("—--------【charac_stat】---------", 14)
        user:SendNotiPacketMessage("village     角色所在的城镇", 14)
        user:SendNotiPacketMessage("fatigue     减少的疲劳值", 14)
        user:SendNotiPacketMessage("used_fatigue   已使用的疲劳值  0-5", 14)
        user:SendNotiPacketMessage("HP   虚弱0-100", 14)
        user:SendNotiPacketMessage("luck_point     幸运点", 14)
        user:SendNotiPacketMessage("expert_job_exp      副职业经验值0-2054", 14)
        user:SendNotiPacketMessage("fatigue_grownup_buff  疲劳蓄电池", 14)

--更改指定玩家的在表【charac_stat】中的信息
	elseif string.match(input, "//set2") and string.len(input) > 6 then

		if string.match(input, "+") and string.match(input, "=") then
			local a = string.find(input, "+")
			local b = string.find(input, "=")
			local x = string.sub(input, 7, a-1)
			local y = string.sub(input, a+1, b-1)
			local z = tonumber(string.sub(input, b+1))

        dpx.sqlexec(game.DBType.taiwan_cain, "update charac_stat set " .. x .. "=" .. z .. " where charac_no=" .. y .. "")

        user:SendNotiPacketMessage(string.format("已更改 玩家【%s】 表【charac_stat】 列【%s】 值【%s】 ", y, x, z), 14)
        local logFile = io.open("/dp2/script/rizhi.log", "a")  
            if logFile then
                local logMsg = string.format("%s	%d	%s	set	玩家%s	表charac_stat 列%s 值%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), y, x, z)
                logFile:write(logMsg)  
                logFile:close()  
            end
		
		end

--更改指定玩家的在表【member_dungeon】中的信息
	elseif string.match(input, "//set3") and string.len(input) > 6 then

		local x = string.sub(input, 7)
        dpx.sqlexec(game.DBType.taiwan_cain, "update member_dungeon set dungeon='2|3,3|3,4|3,5|3,6|3,7|3,8|3,9|3,11|3,12|3,13|3,14|3,15|3,17|3,21|3,22|3,23|3,24|3,25|3,26|3,27|3,31|3,32|3,33|3,34|3,35|3,36|3,37|3,40|3,42|3,43|3,44|3,45|3,50|3,51|3,52|3,53|3,60|3,61|3,65|2,66|1,67|2,70|3,71|3,72|3,73|3,74|3,75|3,76|3,77|3,80|3,81|3,82|3,83|3,84|3,85|3,86|3,87|3,88|3,89|3,90|3,91|2,92|3,93|3,100|3,101|3,102|3,103|3,104|3,110|3,111|3,112|3,140|3,141|3,502|3,511|3,521|3,1000|3,1500|3,1501|3,1502|3,1504|1,1506|3,3506|3,10000|3' where m_id=" .. x .. "")

        user:SendNotiPacketMessage(string.format("已开启 账号【%s】 所有副本难度", x), 14)
        local logFile = io.open("/dp2/script/rizhi.log", "a")  
            if logFile then
                local logMsg = string.format("%s	%d	%s	set	账号%s 所有副本难度\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
                logFile:write(logMsg)  
                logFile:close()  
            end
		
--更改指定玩家的在表【charac_tower_despair】中的信息
	elseif string.match(input, "//set4") and string.len(input) > 6 then

		if string.match(input, "=") then
			local a = string.find(input, "=")
			local x = string.sub(input, 7, a-1)
			local y = string.sub(input, a+1)

        dpx.sqlexec(game.DBType.taiwan_cain, "update charac_tower_despair set last_clear_layer=" .. y .. " where charac_no=" .. x .. "")

        user:SendNotiPacketMessage(string.format("已更改 玩家【%s】 表【charac_tower_despair】 列【last_clear_layer】 值【%s】 ", x, y), 14)
        local logFile = io.open("/dp2/script/rizhi.log", "a")  
            if logFile then
                local logMsg = string.format("%s	%d	%s	set	玩家%s	表charac_tower_despair 列last_clear_layer 值%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), y, x, z)
                logFile:write(logMsg)  
                logFile:close()  
            end
		
		end


----------------------------------------------------------------------------以下是每日签到----------------------------------------------------------------------------
--每天可签到一次，每天6点重置次数，若变更了dp或./run，可再次签到
	elseif input == "//qd" then
        local currentTime = os.time()
        local lastMidnight = os.time({year=os.date("*t", currentTime).year, month=os.date("*t", currentTime).month, day=os.date("*t", currentTime).day, hour=0, min=0, sec=0})
        local nextSixAM = lastMidnight + 24 * 3600 + 6 * 3600  -- 下一天的早上6点
        local cooldown = nextSixAM - currentTime  -- 到下一天早上6点的剩余时间

        if lastSignInTime[user:GetCharacNo()] and currentTime - lastSignInTime[user:GetCharacNo()] < cooldown then
            user:SendNotiPacketMessage("——————————每日签到——————————  您今天已经签到完毕，请勿重复签到！           距离下次签到剩余时间：" .. cooldown .. "秒", 14)
            return 0
        end

        dpx.mail.item(user:GetCharacNo(), 3, "每日签到", "感谢您的支持", "3340", "1")--3340为道具，1为数量
        sendPacketMessage(string.format("玩家【%s】通过每日签到获得了丰厚的奖励，快来试试吧！聊天框输入//qd", user:GetCharacName()), 15)
        user:SendNotiPacketMessage("——————————每日签到——————————  签到奖励发送至邮箱，若空邮件请小退一下!", 14)

        lastSignInTime[user:GetCharacNo()] = currentTime

        local logFile = io.open("/dp2/script/rizhi.log", "a")  
        if logFile then
            local logMsg = string.format("%s	%d	%s	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), "签到成功")
            logFile:write(logMsg)  
            logFile:close()  
        end

        return 0
		
----------------------------------------------------------------------------以下是充值点券----------------------------------------------------------------------------
	elseif input == "//cz" then
        user:SendNotiPacketMessage("——————————充值相关—————————", 14)
        user:SendNotiPacketMessage("   //czdqX  X为充值点券的数量\n//czdbX  X为充值代币的数量\n//czsdX  X为充值胜点的数量\n//czspX  X为充值SP的数量\n//cztpX  X为充值TP的数量\n//czqpX  X为充值QP的数量", 14)

	elseif string.match(input, "//czdq") and string.len(input) > 6 then
	    local x = tonumber(string.sub(input, 7))
		user:ChargeCera(x)
        user:SendNotiPacketMessage(string.format("已充值%d点券", x), 14)
		sendPacketMessage(string.format("——————————通报批评—————————-\n 禽兽玩家：【%s】\n 指令充值：【点券】\n 获得数量：【%s】", user:GetCharacName(), x), 15)
   		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
           	local logMsg = string.format("%s	%d	%s	指令充值	点券	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
           	logFile:write(logMsg)  
           	logFile:close()  
       	end	
		
	elseif string.match(input, "//czdb") and string.len(input) > 6 then
	    local x = tonumber(string.sub(input, 7))
		user:ChargeCeraPoint(x)
        user:SendNotiPacketMessage(string.format("已充值%d代币", x), 14)
		sendPacketMessage(string.format("——————————通报批评—————————-\n 禽兽玩家：【%s】\n 指令充值：【代币】\n 获得数量：【%s】", user:GetCharacName(), x), 15)
   		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
           	local logMsg = string.format("%s	%d	%s	指令充值	代币	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
           	logFile:write(logMsg)  
           	logFile:close()  
       	end	

	elseif string.match(input, "//czsd") and string.len(input) > 6 then
	    local x = tonumber(string.sub(input, 7))
		user:GainWinPoint(x)
        user:SendNotiPacketMessage(string.format("已充值%d胜点", x), 14)
		sendPacketMessage(string.format("——————————通报批评—————————-\n 禽兽玩家：【%s】\n 指令充值：【胜点】\n 获得数量：【%s】", user:GetCharacName(), x), 15)
   		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
           	local logMsg = string.format("%s	%d	%s	指令充值	胜点	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
           	logFile:write(logMsg)  
           	logFile:close()  
       	end	

	elseif string.match(input, "//czsp") and string.len(input) > 6 then
		local x = tonumber(string.sub(input, 7))
        dpx.sqlexec(game.DBType.taiwan_cain_2nd, "update skill set remain_sp=remain_sp+" .. x .. " where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage(string.format("已充值%d SP，请切换角色以生效", x), 14)
		sendPacketMessage(string.format("——————————通报批评—————————-\n 禽兽玩家：【%s】\n 指令充值：【SP】\n 获得数量：【%s】", user:GetCharacName(), x), 15)
   		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
           	local logMsg = string.format("%s	%d	%s	指令充值	SP	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
           	logFile:write(logMsg)  
           	logFile:close()  
       	end	
		
	elseif string.match(input, "//cztp") and string.len(input) > 6 then
	    local x = tonumber(string.sub(input, 7))
		dpx.sqlexec(game.DBType.taiwan_cain_2nd, "update skill set remain_sfp_1st=remain_sfp_1st+" .. x .. " where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage(string.format("已充值%d TP，请切换角色以生效", x), 14)
		sendPacketMessage(string.format("——————————通报批评—————————-\n 禽兽玩家：【%s】\n 指令充值：【TP】\n 获得数量：【%s】", user:GetCharacName(), x), 15)
   		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
           	local logMsg = string.format("%s	%d	%s	指令充值	TP	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
           	logFile:write(logMsg)  
           	logFile:close()  
       	end	

	elseif string.match(input, "//czqp") and string.len(input) > 6 then
	    local x = tonumber(string.sub(input, 7))
		dpx.sqlexec(game.DBType.taiwan_cain, "update charac_quest_shop set qp=qp+" .. x .. " where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage(string.format("已充值%d QP，请切换角色以生效", x), 14)
		sendPacketMessage(string.format("——————————通报批评—————————-\n 禽兽玩家：【%s】\n 指令充值：【QP】\n 获得数量：【%s】", user:GetCharacName(), x), 15)
   		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
           	local logMsg = string.format("%s	%d	%s	指令充值	QP	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
           	logFile:write(logMsg)  
           	logFile:close()  
       	end	

----------------------------------------------------------------------------以下是查询物品----------------------------------------------------------------------------
	elseif input == "//view" then
        user:SendNotiPacketMessage("——————————查询代码—————————-\n //viewidM       查询名称为M的物品的代码\n //viewnameM    查询代码为M的物品的名称", 14)
	

	elseif string.match(input, "//viewid") and string.len(input) > 8 then
		local name = string.sub(input, 9)
		local info = dpx.item.query_by_name(name)
		if info then
			user:SendNotiPacketMessage(string.format("——————————查询成功—————————-\n 查询对象：【%s】\n 查询结果：【%s】", info.name, info.id), 14)
		else
			user:SendNotiPacketMessage("——————————查询失败—————————-\n 未找到此物品或未启用繁体输入法", 14)
		end

	elseif string.match(input, "//viewname") and string.len(input) > 10 then
		local id = tonumber(string.sub(input, 11))
		if id then
			local info = dpx.item.query_by_id(id)
			if info then
				user:SendNotiPacketMessage(string.format("——————————查询成功—————————-\n 查询对象：【%s】\n 查询结果：【%s】", info.id, info.name), 14)
			else
				user:SendNotiPacketMessage("——————————查询失败—————————-\n 未找到此代码", 14)
			end
		end

----------------------------------------------------------------------------以下是发送物品----------------------------------------------------------------------------
	elseif input == "//send" then
        user:SendNotiPacketMessage("——————————发放物品—————————-\n//sendM      发放代码M,数量1个\n//sendMxN    发放代码M,数量N个\n//sendM+N    发放M,强化等级N\n//sendM+NxP 发放代码M,强化等级N，发放P次", 14)

	elseif string.match(input, "//send") and string.len(input) > 6 then
	
		if string.match(input, "+") and string.match(input, "x") then
			local a = string.find(input, "+")
			local b = string.find(input, "x")
			local id = tonumber(string.sub(input, 7, a-1))
	    	local up = tonumber(string.sub(input, a+1, b-1))
			local c = tonumber(string.sub(input, b+1))
			local q = 0
			if id then
			    for i = 1, c, 1 do
                dpx.item.add(user.cptr, id, 1, up)
			    q = q + 1
            end
				sendPacketMessage(string.format("——————————通报批评—————————-\n 禽兽玩家：【%s】\n 指令获得：【%s】\n 强化等级：【%s】\n 获得数量：【%s】", user:GetCharacName(), id, up, q), 15)
				--以下是日志记录
                local logFile = io.open("/dp2/script/rizhi.log", "a")  
                if logFile then
                    local logMsg = string.format("%s	%d	%s	指令发送	%s	强化 %s	数量 %s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), id, up, q)
                    logFile:write(logMsg)  
                    logFile:close()  
                end
	    end
		
		elseif string.match(input, "+") then
			local i = string.find(input, "+")
	    	local up = tonumber(string.sub(input, i+1))
			local id = tonumber(string.sub(input, 7, i-1))
			if id then
				dpx.item.add(user.cptr, id, 1, up)
				sendPacketMessage(string.format("——————————通报批评—————————-\n 禽兽玩家：【%s】\n 指令获得：【%s】\n 强化等级：【%s】\n 获得数量：【1】", user:GetCharacName(), id, up), 15)
				--以下是日志记录
                local logFile = io.open("/dp2/script/rizhi.log", "a")  
                if logFile then
                    local logMsg = string.format("%s	%d	%s	指令发送	%s	强化 %s	数量 1\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), id, up)
                    logFile:write(logMsg)  
                    logFile:close()  
                end
	    end
		elseif string.match(input, "x") then
			local i = string.find(input, "x")
			local count = tonumber(string.sub(input, i+1))
			local id = tonumber(string.sub(input, 7, i-1))
			if id then
				dpx.item.add(user.cptr, id, count)
				sendPacketMessage(string.format("——————————通报批评—————————-\n 禽兽玩家：【%s】\n 指令获得：【%s】\n 获得数量：【%s】", user:GetCharacName(), id, count), 15)
				--以下是日志记录
                local logFile = io.open("/dp2/script/rizhi.log", "a")  
                if logFile then
                    local logMsg = string.format("%s	%d	%s	指令发送	%s	数量 %s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), id, count)
                    logFile:write(logMsg)  
                    logFile:close()  
                end
			end
		else
			local id = tonumber(string.sub(input, 7))
			if id then
				dpx.item.add(user.cptr, id)
				sendPacketMessage(string.format("——————————通报批评—————————-\n 禽兽玩家：【%s】\n 指令获得：【%s】\n 获得数量：【1】", user:GetCharacName(), id), 15)
				--以下是日志记录
                local logFile = io.open("/dp2/script/rizhi.log", "a")  
                if logFile then
                    local logMsg = string.format("%s	%d	%s	指令发送	%s	数量 1\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), id)
                    logFile:write(logMsg)  
                    logFile:close()  
                end
			end
		end

----------------------------------------------------------------------------以下是设置等级----------------------------------------------------------------------------
	elseif input == "//setlv" then
		user:SendNotiPacketMessage("——————————设置等级——————————\n      指令  //setlvX   X为需要设置的等级,X只能为数字", 14)

	elseif string.match(input, "//setlv") and string.len(input) > 7 then
		local x = tonumber(string.sub(input, 8))
        user:SetCharacLevel(x)
        user:SendNotiPacketMessage(string.format("玩家等级设置为： %s级", x), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a") 
   			if logFile then
	          	local logMsg = string.format("%s	%d	%s	指令设置等级	%s级\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
    	       	logFile:write(logMsg)  
        		logFile:close()  
			end	

----------------------------------------------------------------------------以下是接取任务----------------------------------------------------------------------------
	elseif input == "//getq" then
		user:SendNotiPacketMessage("——————————接取任务——————————\n      指令  //getqM   M为强制接取的任务编号\n      慎重使用，某些任务强制接取后会炸角色，如999", 14)
	
	elseif string.match(input, "//getq") and string.len(input) > 6 then
		local q = tonumber(string.sub(input, 7))
        local ok = dpx.quest.accept(user.cptr, q, true)
        user:SendNotiPacketMessage(string.format("已强制接取任务，编号【%s】", q), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   			if logFile then
          	    local logMsg = string.format("%s	%d	%s	指令接取	任务编号	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
           	    logFile:write(logMsg)  
           	logFile:close()  
        	end	
            if not ok then
            dpx.item.add(user.cptr, item_id)
		    user:SendNotiPacketMessage("无可接取任务", 14)
            end
----------------------------------------------------------------------------以下是清理任务----------------------------------------------------------------------------
--以下是清理符合等级的所有任务
	elseif input == "//clearq" then
		user:SendNotiPacketMessage("——————————清理任务——————————", 14)
		user:SendNotiPacketMessage("    指令  //clearqall  清理所有任务\n 指令  //clearqe     清理主线任务\n 指令  //clearqa     清理成就任务\n 指令  //clearqn     清理普通任务\n 指令  //clearqd     清理每日任务", 14)
	
	elseif input == "//clearqall" then
        local quest = dpx.quest
        local lst = quest.all(user.cptr)
        local chr_level = user:GetCharacLevel()
        local q = 0
   
        for i, v in ipairs(lst) do
            local id = v
            local info = quest.info(user.cptr, id)
            if info then
                if not info.is_cleared and info.min_level <= chr_level then
                    quest.clear(user.cptr, id)
	    			q = q + 1
                end
            end
        end
        if q > 0 then
            quest.update(user.cptr)
            user:SendNotiPacketMessage(string.format(" 已清理%d个任务！", q), 14)
			local logFile = io.open("/dp2/script/rizhi.log", "a")  
   			    if logFile then
          	     	local logMsg = string.format("%s	%d	%s	指令清理	所有任务	%d个\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
           	    	logFile:write(logMsg)  
           	 	logFile:close()  
        		end	
        else
            user:SendNotiPacketMessage("无可清理任务！", 14)
        end
--以下是清理符合等级的主线任务	
	elseif input == "//clearqe" then
        local quest = dpx.quest
        local lst = quest.all(user.cptr)
        local chr_level = user:GetCharacLevel()
        local q = 0
   
        for i, v in ipairs(lst) do
            local id = v
            local info = quest.info(user.cptr, id)
            if info then
                if not info.is_cleared and info.type == game.QuestType.epic and info.min_level <= chr_level then
                    quest.clear(user.cptr, id)
	    			q = q + 1
                end
            end
        end
        if q > 0 then
            quest.update(user.cptr)
            user:SendNotiPacketMessage(string.format(" 已清理%d个主线任务！", q), 14)
			local logFile = io.open("/dp2/script/rizhi.log", "a")  
   			    if logFile then
          	     	local logMsg = string.format("%s	%d	%s	指令清理	主线任务	%d个\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
           	    	logFile:write(logMsg)  
           	 	logFile:close()  
        		end	
        else
            user:SendNotiPacketMessage("无可清理主线任务！", 14)
        end
--以下是清理符合等级的成就任务
	elseif input == "//clearqa" then
        local quest = dpx.quest
        local lst = quest.all(user.cptr)
        local chr_level = user:GetCharacLevel()
        local q = 0
   
        for i, v in ipairs(lst) do
            local id = v
            local info = quest.info(user.cptr, id)
            if info then
                if not info.is_cleared and info.type == game.QuestType.achievement and info.min_level <= chr_level then
                    quest.clear(user.cptr, id)
	    			q = q + 1
                end
            end
        end
        if q > 0 then
            quest.update(user.cptr)
            user:SendNotiPacketMessage(string.format(" 已清理%d个成就任务！", q), 14)
			local logFile = io.open("/dp2/script/rizhi.log", "a")  
   			    if logFile then
          	     	local logMsg = string.format("%s	%d	%s	指令清理	成就任务	%d个\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
           	    	logFile:write(logMsg)  
           	 	logFile:close()  
        		end	
        else
            user:SendNotiPacketMessage("无可清理成就任务！", 14)
        end
--以下是清理符合等级的普通任务
	elseif input == "//clearqn" then
        local quest = dpx.quest
        local lst = quest.all(user.cptr)
        local chr_level = user:GetCharacLevel()
        local q = 0
   
        for i, v in ipairs(lst) do
            local id = v
            local info = quest.info(user.cptr, id)
            if info then
                if not info.is_cleared and info.type == game.QuestType.common_unique and info.min_level <= chr_level then
                    quest.clear(user.cptr, id)
	    			q = q + 1
                end
            end
        end
        if q > 0 then
            quest.update(user.cptr)
            user:SendNotiPacketMessage(string.format(" 已清理%d个普通任务！", q), 14)
			local logFile = io.open("/dp2/script/rizhi.log", "a")  
   			    if logFile then
          	     	local logMsg = string.format("%s	%d	%s	指令清理	普通任务	%d个\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
           	    	logFile:write(logMsg)  
           	 	logFile:close()  
        		end	
        else
            user:SendNotiPacketMessage("无可清理普通任务！", 14)
        end
--以下是清理符合等级的每日任务
	elseif input == "//clearqd" then
        local quest = dpx.quest
        local lst = quest.all(user.cptr)
        local chr_level = user:GetCharacLevel()
        local q = 0
   
        for i, v in ipairs(lst) do
            local id = v
            local info = quest.info(user.cptr, id)
            if info then
                if not info.is_cleared and info.type == game.QuestType.daily and info.min_level <= chr_level then
                    quest.clear(user.cptr, id)
	    			q = q + 1
                end
            end
        end
        if q > 0 then
            quest.update(user.cptr)
            user:SendNotiPacketMessage(string.format(" 已清理%d个每日任务！", q), 14)
			local logFile = io.open("/dp2/script/rizhi.log", "a")  
   			    if logFile then
          	     	local logMsg = string.format("%s	%d	%s	指令清理	每日任务	%d个\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
           	    	logFile:write(logMsg)  
           	 	logFile:close()  
        		end	
        else
            user:SendNotiPacketMessage("无可清理每日任务！", 14)
        end

----------------------------------------------------------------------------以下是职业相关----------------------------------------------------------------------------
	elseif input == "//zhiye" then
        user:SendNotiPacketMessage("——————————职业相关—————————-\n //job     职业变更\n //grow   角色转职\n //wake   角色觉醒", 14)

--以下是职业变更
	elseif input == "//job" then
        user:SendNotiPacketMessage("——————————职业变更—————————-", 14)
        user:SendNotiPacketMessage("    指令    job0     鬼剑士", 14)
        user:SendNotiPacketMessage("    指令    job1     女格斗", 14)
        user:SendNotiPacketMessage("    指令    job2     男枪手", 14)
        user:SendNotiPacketMessage("    指令    job3     女法师", 14)
        user:SendNotiPacketMessage("    指令    job4     圣职者", 14)
        user:SendNotiPacketMessage("    指令    job5     女枪手", 14)
        user:SendNotiPacketMessage("    指令    job6     暗夜使者", 14)
        user:SendNotiPacketMessage("    指令    job7     男格斗", 14)
        user:SendNotiPacketMessage("    指令    job8     男法师", 14)
        user:SendNotiPacketMessage("    指令    job9     黑暗武士", 14)
        user:SendNotiPacketMessage("    指令    job10    缔造者", 14)
	
	elseif string.match(input, "//job") and string.len(input) > 5 then
	    local x = tonumber(string.sub(input, 6))
		if x >=0 and x <= 10 then
        dpx.sqlexec(game.DBType.taiwan_cain, "update charac_info set job=" .. x .. " where charac_no=" .. user:GetCharacNo() .. "")
      	    user:SendNotiPacketMessage(string.format("职业已变更为：【%s】，请切换角色并初始化SP以生效", x), 14)
        	local logFile = io.open("/dp2/script/rizhi.log", "a")  
            	if logFile then
                	local logMsg = string.format("%s	%d	%s	指令修改 职业为 %s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
                	logFile:write(logMsg)  
                	logFile:close()  
            	end
		else
			user:SendNotiPacketMessage(string.format("职业无法变更为：【%s】", x), 14)
		end

--以下是角色转职
	elseif input == "//grow" then
        user:SendNotiPacketMessage("——————————角色转职—————————-", 14)
        user:SendNotiPacketMessage("指令  grow0 grow1 grow2 grow3 grow4", 14)
        user:SendNotiPacketMessage("职业  鬼剑  剑魂  鬼泣  狂战  修罗", 14)
        user:SendNotiPacketMessage("职业  格斗  气功  散打  街霸  柔道", 14)
        user:SendNotiPacketMessage("职业  枪手  漫游  枪炮  机械  弹药", 14)
        user:SendNotiPacketMessage("职业  女法  元素  召唤  战法  魔道", 14)
        user:SendNotiPacketMessage("职业  圣职  圣骑  蓝拳  驱魔  复仇", 14)
        user:SendNotiPacketMessage("职业  男法  元素  冰结  无     无", 14)
        user:SendNotiPacketMessage("职业  暗夜  刺客  死灵  无     无", 14)
        user:SendNotiPacketMessage("职业  黑武  无    无     无     无", 14)
        user:SendNotiPacketMessage("职业  缔造  无    无     无     无", 14)

	elseif string.match(input, "//grow") and string.len(input) > 6 then
	    local x = tonumber(string.sub(input, 7))
		if x >=0 and x <= 5 then
		user:ChangeGrowType(x, 0)
      	    user:SendNotiPacketMessage(string.format("转职已变更为：【%s】，请切换角色并初始化SP以生效", x), 14)
        	local logFile = io.open("/dp2/script/rizhi.log", "a")  
            	if logFile then
                	local logMsg = string.format("%s	%d	%s	指令修改 转职为 %s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
                	logFile:write(logMsg)  
                	logFile:close()  
            	end
		else
			user:SendNotiPacketMessage(string.format("转职无法变更为：【%s】", x), 14)
		end

--以下是角色觉醒
	elseif input == "//wake" then
        user:SendNotiPacketMessage("——————————角色觉醒—————————\n指令  //wake1   角色进行一次觉醒\n指令  //wake2   角色进行二次觉醒", 14)
--以下是一次觉醒
	elseif input == "//wake1" then
		local growType = user:GetCharacGrowType()
        user:ChangeGrowType(growType, 1)
        user:SendNotiPacketMessage("一次觉醒成功", 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
        if logFile then
            local logMsg = string.format("%s	%d	%s	指令觉醒	一觉	%d\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), user:GetCharacNo())
            logFile:write(logMsg)  
            logFile:close()  
        end
--以下是二次觉醒
	elseif input == "//wake2" then
		local growType = user:GetCharacGrowType()
        user:ChangeGrowType(growType-16, 2)
        user:SendNotiPacketMessage("二次觉醒成功", 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
        if logFile then
            local logMsg = string.format("%s	%d	%s	指令觉醒	二觉	%d\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), user:GetCharacNo())
            logFile:write(logMsg)  
            logFile:close()  
        end

----------------------------------------------------------------------------以下是决斗信息----------------------------------------------------------------------------
	elseif input == "//pvp" then
        user:SendNotiPacketMessage("——————————决斗信息—————————", 14)
        user:SendNotiPacketMessage("   指令  //pvpgX  设置决斗等级为X（0-34）", 14)
        user:SendNotiPacketMessage("   指令  //pvpeX  设置决斗经验为X", 14)
        user:SendNotiPacketMessage("   指令  //pvppX  设置决斗胜点为X", 14)
        user:SendNotiPacketMessage("   指令  //pvpwX  设置决斗胜场为X", 14)
        user:SendNotiPacketMessage("   指令  //pvplX  设置决斗败场为X", 14)

--以下是设置决斗等级
	elseif string.match(input, "//pvpg") and string.len(input) > 6 then
	    local x = tonumber(string.sub(input, 7))
        dpx.sqlexec(game.DBType.taiwan_cain, "update taiwan_cain.pvp_result set pvp_grade=" .. x .. " where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage(string.format("设置决斗等级为：%s 请切换角色以生效", x), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
            local logMsg = string.format("%s	%d	%s	指令设置	决斗等级	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
            logFile:write(logMsg)  
        logFile:close()  
        end	
--以下是设置决斗经验
	elseif string.match(input, "//pvpe") and string.len(input) > 6 then
	    local x = tonumber(string.sub(input, 7))
        dpx.sqlexec(game.DBType.taiwan_cain, "update taiwan_cain.pvp_result set pvp_point=" .. x .. " where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage(string.format("设置决斗经验为：%s 请切换角色以生效", x), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
            local logMsg = string.format("%s	%d	%s	指令设置	决斗经验	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
            logFile:write(logMsg)  
        logFile:close()  
        end
--以下是设置决斗胜点
	elseif string.match(input, "//pvpp") and string.len(input) > 6 then
	    local x = tonumber(string.sub(input, 7))
        dpx.sqlexec(game.DBType.taiwan_cain, "update taiwan_cain.pvp_result set win_point=" .. x .. " where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage(string.format("设置决斗胜点为：%s 请切换角色以生效", x), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
            local logMsg = string.format("%s	%d	%s	指令设置	决斗胜点	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
            logFile:write(logMsg)  
        logFile:close()  
        end	
--以下是设置决斗胜场
	elseif string.match(input, "//pvpw") and string.len(input) > 6 then
	    local x = tonumber(string.sub(input, 7))
        dpx.sqlexec(game.DBType.taiwan_cain, "update taiwan_cain.pvp_result set win=" .. x .. " where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage(string.format("设置决斗胜场为：%s 请切换角色以生效", x), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
            local logMsg = string.format("%s	%d	%s	指令设置	决斗胜场	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
            logFile:write(logMsg)  
        logFile:close()  
        end	
--以下是设置决斗败场
	elseif string.match(input, "//pvpl") and string.len(input) > 6 then
	    local x = tonumber(string.sub(input, 7))
        dpx.sqlexec(game.DBType.taiwan_cain, "update taiwan_cain.pvp_result set lose=" .. x .. " where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage(string.format("设置决斗败场为：%s 请切换角色以生效", x), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
            local logMsg = string.format("%s	%d	%s	指令设置	决斗败场	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
            logFile:write(logMsg)  
        logFile:close()  
        end	

----------------------------------------------------------------------------以下是清理背包----------------------------------------------------------------------------
	elseif input == "//clearp" then
        user:SendNotiPacketMessage("——————————清理背包—————————-", 14)
        user:SendNotiPacketMessage(" //clearpe     清理装备栏", 14)
		user:SendNotiPacketMessage(" //clearpw     清理消耗品栏,每格数量-1", 14)
        user:SendNotiPacketMessage(" //clearpm     清理材料栏,每格数量-1", 14)
        user:SendNotiPacketMessage(" //clearpq     清理任务栏,每格数量-1", 14)
		user:SendNotiPacketMessage(" //clearpq     清理副职业栏,每格数量-1", 14)
		user:SendNotiPacketMessage(" //clearpq     清理徽章栏,每格数量-1", 14)
        user:SendNotiPacketMessage(" //clearpa     清理装扮栏", 14)
        user:SendNotiPacketMessage(" //clearpc     清理宠物栏", 14)
        user:SendNotiPacketMessage(" //clearpce    清理宠物装备栏", 14)
        user:SendNotiPacketMessage(" //clearpcw    清理宠物消耗品栏,每格数量-1", 14)
--以下是清理背包中装备栏
	elseif input == "//clearpe" then
    local q = 0
    for i = 9, 56, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
			dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
            q = q +1
        end
    end
    if q > 0 then
        user:SendItemSpace(game.ItemSpace.INVENTORY)
        user:SendNotiPacketMessage(string.format("清理成功，%d个装备已清理", q), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		    if logFile then
               	local logMsg = string.format("%s	%d	%s	指令清理	装备	%s个\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
               	logFile:write(logMsg)  
            	logFile:close()  
        	end	
    else
        user:SendNotiPacketMessage("清理失败，装备栏为空", 14)
    end
--以下是清理背包中消耗品栏，每种只能清理1个
	elseif input == "//clearpw" then
    local q = 0
    for i = 57, 104, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
			dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
            q = q +1
        end
    end
    if q > 0 then
        user:SendItemSpace(game.ItemSpace.INVENTORY)
        user:SendNotiPacketMessage(string.format("清理成功，%d个消耗品已清理", q), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		    if logFile then
               	local logMsg = string.format("%s	%d	%s	指令清理	消耗品	%s个\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
               	logFile:write(logMsg)  
            	logFile:close()  
        	end	
    else
        user:SendNotiPacketMessage("清理失败，消耗品栏为空", 14)
    end
--以下是清理背包中材料栏，每种只能清理1个
	elseif input == "//clearpm" then
    local q = 0
    for i = 105, 152, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
			dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
            q = q +1
        end
    end
    if q > 0 then
        user:SendItemSpace(game.ItemSpace.INVENTORY)
        user:SendNotiPacketMessage(string.format("清理成功，%d个材料已清理", q), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		    if logFile then
               	local logMsg = string.format("%s	%d	%s	指令清理	材料	%s个\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
               	logFile:write(logMsg)  
            	logFile:close()  
        	end	
    else
        user:SendNotiPacketMessage("清理失败，材料栏为空", 14)
    end
--以下是清理背包中任务栏，每种只能清理1个
	elseif input == "//clearpq" then
    local q = 0
    for i = 153, 200, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
			dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
            q = q +1
        end
    end
    if q > 0 then
        user:SendItemSpace(game.ItemSpace.INVENTORY)
        user:SendNotiPacketMessage(string.format("清理成功，%d个任务物品已清理", q), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		    if logFile then
               	local logMsg = string.format("%s	%d	%s	指令清理	任务物品	%s个\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
               	logFile:write(logMsg)  
            	logFile:close()  
        	end	
    else
        user:SendNotiPacketMessage("清理失败，任务栏为空", 14)
    end
--以下是清理背包中副职业材料栏，每种只能清理1个
	elseif input == "//clearpf" then
    local q = 0
    for i = 201, 248, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
			dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
            q = q +1
        end
    end
    if q > 0 then
        user:SendItemSpace(game.ItemSpace.INVENTORY)
        user:SendNotiPacketMessage(string.format("清理成功，%d个副职业材料已清理", q), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		    if logFile then
               	local logMsg = string.format("%s	%d	%s	指令清理	副职业材料	%s个\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
               	logFile:write(logMsg)  
            	logFile:close()  
        	end	
    else
        user:SendNotiPacketMessage("清理失败，副职业材料栏为空", 14)
    end
--以下是清理背包中徽章栏，每种只能清理1个
	elseif input == "//clearph" then
    local q = 0
    for i = 249, 311, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
			dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
            q = q +1
        end
    end
    if q > 0 then
        user:SendItemSpace(game.ItemSpace.INVENTORY)
        user:SendNotiPacketMessage(string.format("清理成功，%d个徽章已清理", q), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		    if logFile then
               	local logMsg = string.format("%s	%d	%s	指令清理	徽章	%s个\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
               	logFile:write(logMsg)  
            	logFile:close()  
        	end	
    else
        user:SendNotiPacketMessage("清理失败，徽章栏为空", 14)
    end
--以下是清理背包中装扮栏
	elseif input == "//clearpa" then
    local q = 0
	for i = 0, 104, 1 do
		local info = dpx.item.info(user.cptr, 1, i)
		if info then
			dpx.item.delete(user.cptr, 1, i, 1)
            q = q + 1
		end
	end
    if q > 0 then
        user:SendItemSpace(1)
        user:SendNotiPacketMessage(string.format("清理成功，%d件装扮已清理", q), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		    if logFile then
               	local logMsg = string.format("%s	%d	%s	指令清理	装扮	%s件\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
               	logFile:write(logMsg)  
            	logFile:close()  
        	end	
    else
        user:SendNotiPacketMessage("清理失败，装扮栏为空", 14)
    end
--以下是清理背包中宠物栏
	elseif input == "//clearpc" then
    local q = 0
    for i = 0, 139, 1 do
        local info = dpx.item.info(user.cptr, 7, i)
        if info then
			dpx.item.delete(user.cptr, 7, i, 1)
            q = q +1
        end
    end
    if q > 0 then
        user:SendItemSpace(7)
        user:SendNotiPacketMessage(string.format("清理成功，%d个宠物已清理", q), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		    if logFile then
               	local logMsg = string.format("%s	%d	%s	指令清理	宠物	%s个\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
               	logFile:write(logMsg)  
            	logFile:close()  
        	end	
    else
        user:SendNotiPacketMessage("清理失败，宠物栏为空", 14)
    end
--以下是清理背包中宠物装备栏
	elseif input == "//clearpce" then
    local q = 0
    for i = 140, 188, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.CREATURE, i)
        if info then
			dpx.item.delete(user.cptr, game.ItemSpace.CREATURE, i, 1)
            q = q +1
        end
    end
    if q > 0 then
        user:SendItemSpace(game.ItemSpace.INVENTORY)
        user:SendNotiPacketMessage(string.format("清理成功，%d个宠物装备已清理", q), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		    if logFile then
               	local logMsg = string.format("%s	%d	%s	指令清理	宠物装备	%s个\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
               	logFile:write(logMsg)  
            	logFile:close()  
        	end	
    else
        user:SendNotiPacketMessage("清理失败，宠物装备栏为空", 14)
    end
--以下是清理背包中宠物消耗品栏
	elseif input == "//clearpcw" then
    local q = 0
    for i = 189, 237, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.CREATURE, i)
        if info then
			dpx.item.delete(user.cptr, game.ItemSpace.CREATURE, i, 1)
            q = q +1
        end
    end
    if q > 0 then
        user:SendItemSpace(game.ItemSpace.INVENTORY)
        user:SendNotiPacketMessage(string.format("清理成功，%d个宠物消耗品已清理", q), 14)
		local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		    if logFile then
               	local logMsg = string.format("%s	%d	%s	指令清理	宠物消耗品	%s个\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), q)
               	logFile:write(logMsg)  
            	logFile:close()  
        	end	
    else
        user:SendNotiPacketMessage("清理失败，宠物消耗品栏为空", 14)
    end

----------------------------------------------------------------------------以下是装备分解----------------------------------------------------------------------------
    elseif input == "//fj1" then
        local q = 0
        for i = 9, 56, 1 do
            local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
            if info then
                user:Disjoint(game.ItemSpace.INVENTORY, i, nil)
                if not dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i) then
                    q = q + 1
                end
            end
        end
        if q > 0 then
            user:SendItemSpace(game.ItemSpace.INVENTORY)
            user:SendNotiPacketMessage(string.format("分解成功， %d件装备已分解", q), 14)
        else
            user:SendNotiPacketMessage("分解失败，", 14)
        end
    elseif input == "//fj2" then
        local q = 0
        for i = 9, 56, 1 do
            local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
            if info then
                user:Disjoint(game.ItemSpace.INVENTORY, i, user)
                if not dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i) then
                    q = q + 1
                end
            end
        end
        if q > 0 then
            user:SendItemSpace(game.ItemSpace.INVENTORY)
            user:SendNotiPacketMessage(string.format("分解成功， %d件装备已分解", q), 14)
        else
            user:SendNotiPacketMessage("分解失败，", 14)
        end

----------------------------------------------------------------------------以下是装备跨界----------------------------------------------------------------------------
	elseif input == "//moveequ" then
        local list = {840000, 840001} -- 不可转移的装备代码
        local boolx = false
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, 9)
        if info then
            for _, _equip in pairs(list) do
                if info.id == _equip then
                    boolx = true
                    break
                end
            end
            if not boolx then
                if not user:MoveToAccCargo(game.ItemSpace.INVENTORY, 9) then
                    user:SendNotiPacketMessage("跨界失败，请确保共享仓库有空余位置", 14)
                else
                    user:SendNotiPacketMessage(string.format("跨界成功，【%s】已转移至共享仓库", info.name), 14)
					local logFile = io.open("/dp2/script/rizhi.log", "a")  
   					    if logFile then
          			     	local logMsg = string.format("%s	%d	%s	指令跨界	%s %s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), info.name, info.id)
           			    	logFile:write(logMsg)  
           			 	logFile:close()  
        				end	
                end
            end
            if boolx then
                user:SendNotiPacketMessage("跨界失败，该物品不可转移", 14)
            end
        else
            user:SendNotiPacketMessage("跨界失败，装备栏第一格无装备", 14)
        end

----------------------------------------------------------------------------以下是装备继承----------------------------------------------------------------------------
	elseif input == "//trans" then
	    user:SendNotiPacketMessage("——————————装备继承——————————\n将装备栏第一格装备的强化/增幅、附魔、锻造转移到第二格装备上", 14)
		user:SendNotiPacketMessage("    指令  //transall   转移全部\n 指令  //transua    转移强化/增幅\n 指令  //transe      转移附魔\n 指令  //transs      转移锻造", 14)
--以下是继承全部属性
	elseif input == "//transall" then
        local mask = game.InheritMask.FLAG_UPGRADE | game.InheritMask.FLAG_AMPLIFY | game.InheritMask.FLAG_ENCHANT | game.InheritMask.FLAG_SEPARATE
        mask = mask | game.InheritMask.FLAG_MOVE_UPGRADE | game.InheritMask.FLAG_MOVE_AMPLIFY | game.InheritMask.FLAG_MOVE_ENCHANT | game.InheritMask.FLAG_MOVE_SEPARATE
        local item1 = dpx.item.info(user, game.ItemSpace.INVENTORY, 9)
        local item2 = dpx.item.info(user, game.ItemSpace.INVENTORY, 10)

        if item1 == nil or item2 == nil then
            user:SendNotiPacketMessage("转移失败，装备栏第一格或第二格无正确装备", 14)
        else dpx.item.inherit(user.cptr, 9, 10, mask)
		    user:SendNotiPacketMessage(string.format("所有数据 已从: 【%s】\n       转至: 【%s】", item1.name, item2.name), 14)
			local logFile = io.open("/dp2/script/rizhi.log", "a")  
   			    if logFile then
          	     	local logMsg = string.format("%s	%d	%s	指令继承 全部属性 %s→%s %s→%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), item1.name, item2.name, item1.id, item2.id)
           	    	logFile:write(logMsg)  
           	 	logFile:close()  
        		end	
        end
--以下是继承强化/增幅
	elseif input == "//transua" then
        local mask = game.InheritMask.FLAG_UPGRADE | game.InheritMask.FLAG_AMPLIFY
        mask = mask | game.InheritMask.FLAG_MOVE_UPGRADE | game.InheritMask.FLAG_MOVE_AMPLIFY
        local item1 = dpx.item.info(user, game.ItemSpace.INVENTORY, 9)
        local item2 = dpx.item.info(user, game.ItemSpace.INVENTORY, 10)

        if item1 == nil or item2 == nil then
            user:SendNotiPacketMessage("转移失败，装备栏第一格或第二格无正确装备", 14)
        else dpx.item.inherit(user.cptr, 9, 10, mask)
		    user:SendNotiPacketMessage(string.format("强化/增幅数据 已从: 【%s】\n       转至: 【%s】", item1.name, item2.name), 14)
			local logFile = io.open("/dp2/script/rizhi.log", "a")  
   			    if logFile then
          	     	local logMsg = string.format("%s	%d	%s	指令继承 强化/增幅 %s→%s %s→%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), item1.name, item2.name, item1.id, item2.id)
           	    	logFile:write(logMsg)   
           	 	logFile:close()  
        		end	
        end
--以下是继承附魔
	elseif input == "//transe" then
        local mask = game.InheritMask.FLAG_ENCHANT
        mask = mask | game.InheritMask.FLAG_MOVE_ENCHANT
        local item1 = dpx.item.info(user, game.ItemSpace.INVENTORY, 9)
        local item2 = dpx.item.info(user, game.ItemSpace.INVENTORY, 10)

        if item1 == nil or item2 == nil then
            user:SendNotiPacketMessage("转移失败，装备栏第一格或第二格无正确装备", 14)
        else dpx.item.inherit(user.cptr, 9, 10, mask)
		    user:SendNotiPacketMessage(string.format("附魔数据 已从: 【%s】\n       转至: 【%s】", item1.name, item2.name), 14)
			local logFile = io.open("/dp2/script/rizhi.log", "a")  
   			    if logFile then
          	     	local logMsg = string.format("%s	%d	%s	指令继承 附魔 %s→%s %s→%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), item1.name, item2.name, item1.id, item2.id)
           	    	logFile:write(logMsg)  
           	 	logFile:close()  
        		end	
        end
--以下是继承锻造
	elseif input == "//transs" then
        local mask = game.InheritMask.FLAG_SEPARATE
        mask = mask | game.InheritMask.FLAG_MOVE_SEPARATE
        local item1 = dpx.item.info(user, game.ItemSpace.INVENTORY, 9)
        local item2 = dpx.item.info(user, game.ItemSpace.INVENTORY, 10)

        if item1 == nil or item2 == nil then
            user:SendNotiPacketMessage("转移失败，装备栏第一格或第二格无正确装备", 14)
        else dpx.item.inherit(user.cptr, 9, 10, mask)
		    user:SendNotiPacketMessage(string.format("锻造数据 已从: 【%s】\n       转至: 【%s】", item1.name, item2.name), 14)
			local logFile = io.open("/dp2/script/rizhi.log", "a")  
   			    if logFile then
          	     	local logMsg = string.format("%s	%d	%s	指令继承 锻造 %s→%s %s→%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), item1.name, item2.name, item1.id, item2.id)
           	    	logFile:write(logMsg) 
           	 	logFile:close()  
        		end	
        end

----------------------------------------------------------------------------以下是异界重置----------------------------------------------------------------------------
	elseif input == "//e23rs" then
        user:ResetDimensionInout(0)
        user:ResetDimensionInout(1)
        user:ResetDimensionInout(2)
        user:ResetDimensionInout(3)
        user:ResetDimensionInout(4)
        user:ResetDimensionInout(5)
        user:SendNotiPacketMessage("异界入场次数已重置", 14)
			local logFile = io.open("/dp2/script/rizhi.log", "a")  
   			    if logFile then
          	     	local logMsg = string.format("%s	%d	%s	指令重置 异界	1次\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName())
           	    	logFile:write(logMsg)  
           	 	logFile:close()  
        		end	

----------------------------------------------------------------------------以下是设置虚弱----------------------------------------------------------------------------
	elseif input == "//weak" then
	    user:SendNotiPacketMessage("——————————设置虚弱——————————\n//weakX  X为角色虚弱度，取值0-100,100时为无虚弱", 14)

	elseif string.match(input, "//weak") and string.len(input) > 6 then

	    local x = tonumber(string.sub(input, 7))
		if x >=0 and x <= 100 then
			user:SetCurCharacStamina(x)
      	    user:SendNotiPacketMessage(string.format("虚弱度已设置为：【%s】", x), 14)
        	local logFile = io.open("/dp2/script/rizhi.log", "a")  
            	if logFile then
                	local logMsg = string.format("%s	%d	%s	指令修改 虚弱度 %s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), x)
                	logFile:write(logMsg)  
                	logFile:close()  
            	end
		else
			user:SendNotiPacketMessage(string.format("虚弱度无法设置为：【%s】", x), 14)
		end

----------------------------------------------------------------------------以下是坐标查询----------------------------------------------------------------------------
--以下是查询城镇坐标
	elseif input == "//postwn" then
		user:SendNotiPacketMessage(string.format("——————————城镇坐标—————————-\n 城镇编号：（%d）\n 区域编号：（%d）\n 角色坐标：（%d， %d）", user:GetLocation()), 14)


--以下是查询副本坐标【功能异常】
	-- elseif input == "//posdgn" then
		-- local dgn = game.fac.dungeon(Dungeon)
		-- local map = game.fac.battle_field(Battle_Field)
		-- local dgnid = dgn:GetIndex()
		-- local mapid = map:GetCurrentMapIndex()
		-- local posx, posy = map:GetCurPos()
		-- if dgnid and mapid and posx and posy then
			-- user:SendNotiPacketMessage(string.format("副本信息： 副本编号（%d）， 房间编号（%d）， 人物坐标（%d， %d）", dgnid, mapid, posx, posy))
		-- end
	end

    return fnext()
end
----------------------------------------------------------------------------指令结束----------------------------------------------------------------------------


----------------------------------------------------------------------------道具开头----------------------------------------------------------------------------
--这里是避免被任务清理券所清理的任务代码，如果有不想被清理的任务，可以填代码到这里，按格式来填！
evade_lst = {}
--以下为所有任务清理券代码 自动符合等级的所有任务（不用就删掉这一大段）!
item_handler[80101] = function(user, item_id)
    local quest = dpx.quest
    local lst = quest.all(user.cptr)
    local chr_level = user:GetCharacLevel()
    local new_lst = {}
	local q = 0
    
    for i, v in ipairs(lst) do
        local is_evade = false
        for j, w in ipairs(evade_lst) do
            if v == w then
                is_evade = true
                break
            end
        end
        if not is_evade then
            new_lst[#new_lst + 1] = v
        end
    end
    
    for i, v in ipairs(lst) do
        local id = v
        local info = quest.info(user.cptr, id)
        if info then
            if not info.is_cleared and info.min_level < chr_level then
               quest.clear(user.cptr, id)
			   q = q + 1
            end
        end
    end
    if q > 0 then
        quest.update(user.cptr)
        user:SendNotiPacketMessage(string.format(" %d个主线任务已清理！", q), 14)
    else
        user:SendNotiPacketMessage("无可清理主线任务！", 14)
        dpx.item.add(user.cptr, item_id)
    end
end
--以下为主线任务清理券代码 自动清理低一级的所有主线任务（不用就删掉这一大段）!
item_handler[80102] = function(user, item_id)
    local quest = dpx.quest
    local lst = quest.all(user.cptr)
    local chr_level = user:GetCharacLevel()
    local new_lst = {}
	local q = 0
    
    for i, v in ipairs(lst) do
        local is_evade = false
        for j, w in ipairs(evade_lst) do
            if v == w then
                is_evade = true
                break
            end
        end
        if not is_evade then
            new_lst[#new_lst + 1] = v
        end
    end
    
    for i, v in ipairs(lst) do
        local id = v
        local info = quest.info(user.cptr, id)
        if info then
            if not info.is_cleared and info.type == game.QuestType.epic and info.min_level < chr_level then
               quest.clear(user.cptr, id)
			   q = q + 1
            end
        end
    end
    if q > 0 then
        quest.update(user.cptr)
        user:SendNotiPacketMessage(string.format(" %d个主线任务已清理！", q), 14)
    else
        user:SendNotiPacketMessage("无可清理主线任务！", 14)
        dpx.item.add(user.cptr, item_id)
    end
end
--以下为成就任务清理券代码 自动清理低一级的所有成就任务（不用就删掉这一大段）!
item_handler[80103] = function(user, item_id)
    local quest = dpx.quest
    local lst = quest.all(user.cptr)
    local chr_level = user:GetCharacLevel()
    local new_lst = {}
	local q = 0
    
    for i, v in ipairs(lst) do
        local is_evade = false
        for j, w in ipairs(evade_lst) do
            if v == w then
                is_evade = true
                break
            end
        end
        if not is_evade then
            new_lst[#new_lst + 1] = v
        end
    end
    
    for i, v in ipairs(lst) do
        local id = v
        local info = quest.info(user.cptr, id)
        if info then
            if not info.is_cleared and info.type == game.QuestType.achievement and info.min_level < chr_level then
               quest.clear(user.cptr, id)
			   q = q + 1
            end
        end
    end
    if q > 0 then
        quest.update(user.cptr)
        user:SendNotiPacketMessage(string.format(" %d个成就任务已清理！", q), 14)
    else
        user:SendNotiPacketMessage("无可清理成就任务！", 14)
        dpx.item.add(user.cptr, item_id)
    end
end
--以下为普通任务清理券代码 自动清理低一级的所有普通任务（不用就删掉这一大段）!
item_handler[80104] = function(user, item_id)
    local quest = dpx.quest
    local lst = quest.all(user.cptr)
    local chr_level = user:GetCharacLevel()
    local new_lst = {}
	local q = 0
    
    for i, v in ipairs(lst) do
        local is_evade = false
        for j, w in ipairs(evade_lst) do
            if v == w then
                is_evade = true
                break
            end
        end
        if not is_evade then
            new_lst[#new_lst + 1] = v
        end
    end
    
    for i, v in ipairs(lst) do
        local id = v
        local info = quest.info(user.cptr, id)
        if info then
            if not info.is_cleared and info.type == game.QuestType.common_unique and info.min_level < chr_level then
               quest.clear(user.cptr, id)
			   q = q + 1
            end
        end
    end
    if q > 0 then
        quest.update(user.cptr)
        user:SendNotiPacketMessage(string.format(" %d个普通任务已清理！", q), 14)
    else
        user:SendNotiPacketMessage("无可清理普通任务！", 14)
        dpx.item.add(user.cptr, item_id)
    end
end
--以下为每日/重复任务清理券代码 自动清理低一级的所有每日任务（不用就删掉这一大段）!
item_handler[80105] = function(user, item_id)
    local quest = dpx.quest
    local lst = quest.all(user.cptr)
    local chr_level = user:GetCharacLevel()
    local new_lst = {}
	local q = 0
    
    for i, v in ipairs(lst) do
        local is_evade = false
        for j, w in ipairs(evade_lst) do
            if v == w then
                is_evade = true
                break
            end
        end
        if not is_evade then
            new_lst[#new_lst + 1] = v
        end
    end
    
    for i, v in ipairs(lst) do
        local id = v
        local info = quest.info(user.cptr, id)
        if info then
            if not info.is_cleared and info.type == game.QuestType.daily and info.min_level < chr_level then
               quest.clear(user.cptr, id)
			   q = q + 1
            end
        end
    end
    if q > 0 then
        quest.update(user.cptr)
        user:SendNotiPacketMessage(string.format(" %d个每日任务已清理！", q), 14)
    else
        user:SendNotiPacketMessage("无可清理每日任务！", 14)
        dpx.item.add(user.cptr, item_id)
    end
end

--以下为经验书，不用就删掉这一段--
item_handler[80106] = function(user, item_id)
    user:AddCharacExpPercent(0.05)
    user:SendNotiPacketMessage("经验值增加 5%%！", 14)
end
item_handler[80107] = function(user, item_id)
    user:AddCharacExpPercent(0.1)
    user:SendNotiPacketMessage("经验值增加 10%%！", 14)
end
item_handler[80108] = function(user, item_id)
    user:AddCharacExpPercent(0.2)
    user:SendNotiPacketMessage("经验值增加 20%%！", 14)
end
item_handler[80109] = function(user, item_id)
    user:AddCharacExpPercent(0.5)
    user:SendNotiPacketMessage("经验值增加 50%%！", 14)
end
item_handler[80110] = function(user, item_id)
    user:AddCharacExpPercent(1.0)
    user:SendNotiPacketMessage("经验值增加 100%%！", 14)
end

--以下为1级升级券代码，可在70级前任意一级使用（不用就删掉这一大段）!
item_handler[80111] = function(user, item_id)
    local x = 1
	local y = user:GetCharacLevel()
	local z = x + y
    if y < 70 then
        user:SetCharacLevel(z)
        user:SendNotiPacketMessage("玩家等级提升", 14)
    else
        dpx.item.add(user.cptr, item_id)
        user:SendNotiPacketMessage("升级失败，角色已满级", 14)
    end
end
--以下为2级升级券代码，可在70级前任意一级使用（不用就删掉这一大段）!
item_handler[80112] = function(user, item_id)
    local x = 2
	local y = user:GetCharacLevel()
	local z = x + y
    if y < 70 then
        user:SetCharacLevel(z)
        user:SendNotiPacketMessage("玩家等级提升", 14)
    else
        dpx.item.add(user.cptr, item_id)
        user:SendNotiPacketMessage("升级失败，角色已满级", 14)
    end
end
--以下为5级升级券代码，可在70级前任意一级使用（不用就删掉这一大段）!
item_handler[80113] = function(user, item_id)
    local x = 5
	local y = user:GetCharacLevel()
	local z = x + y
    if y < 70 then
        user:SetCharacLevel(z)
        user:SendNotiPacketMessage("玩家等级提升", 14)
    else
        dpx.item.add(user.cptr, item_id)
        user:SendNotiPacketMessage("升级失败，角色已满级", 14)
    end
end
--以下为10级升级券代码，可在70级前任意一级使用（不用就删掉这一大段）!
item_handler[80114] = function(user, item_id)
    local x = 10
	local y = user:GetCharacLevel()
	local z = x + y
    if y < 70 then
        user:SetCharacLevel(z)
        user:SendNotiPacketMessage("玩家等级提升", 14)
    else
        dpx.item.add(user.cptr, item_id)
        user:SendNotiPacketMessage("升级失败，角色已满级", 14)
    end
end
--以下为满级升级券代码，可在70级前任意一级使用（不用就删掉这一大段）!
item_handler[80115] = function(user, item_id)
    local x = user:GetCharacLevel()
    if x < 70 then
        user:SetCharacLevel(70)
        user:SendNotiPacketMessage("玩家等级提升", 14)
    else
        dpx.item.add(user.cptr, item_id)
        user:SendNotiPacketMessage("升级失败，角色已满级", 14)
    end
end

--以下为装备回收，不用就删掉这一段--
item_handler[80116] = function(user, item_id)
	local list1 = {22001, 22003} -- 可以回收的装备id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收装备列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 9, 16, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装备后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收装备： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("装备栏第一行无符合回收条件的装备", 14)
    end
end
--以下为装备回收，不用就删掉这一段--
item_handler[80117] = function(user, item_id)
	local list1 = {22001, 22003} -- 可以回收的装备id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收装备列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 9, 16, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装备后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收装备： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("装备栏第一行无符合回收条件的装备", 14)
    end
end
--以下为装备回收，不用就删掉这一段--
item_handler[80118] = function(user, item_id)
	local list1 = {22001, 22003} -- 可以回收的装备id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收装备列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 9, 16, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装备后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收装备： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("装备栏第一行无符合回收条件的装备", 14)
    end
end
--以下为装备回收，不用就删掉这一段--
item_handler[80119] = function(user, item_id)
	local list1 = {22001, 22003} -- 可以回收的装备id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收装备列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 9, 16, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装备后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收装备： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("装备栏第一行无符合回收条件的装备", 14)
    end
end
--以下为装备回收，不用就删掉这一段--
item_handler[80120] = function(user, item_id)
	local list1 = {22001, 22003} -- 可以回收的装备id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收装备列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 9, 16, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装备后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收装备： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("装备栏第一行无符合回收条件的装备", 14)
    end
end
--以下为装备回收，不用就删掉这一段--
item_handler[80121] = function(user, item_id)
	local list1 = {22001, 22003} -- 可以回收的装备id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收装备列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 9, 16, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装备后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收装备： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("装备栏第一行无符合回收条件的装备", 14)
    end
end
--以下为装备回收，不用就删掉这一段--
item_handler[80122] = function(user, item_id)
	local list1 = {22001, 22003} -- 可以回收的装备id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收装备列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 9, 16, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装备后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收装备： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("装备栏第一行无符合回收条件的装备", 14)
    end
end
--以下为装备回收，不用就删掉这一段--
item_handler[80123] = function(user, item_id)
	local list1 = {22001, 22003} -- 可以回收的装备id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收装备列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 9, 16, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装备后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收装备： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("装备栏第一行无符合回收条件的装备", 14)
    end
end
--以下为装备回收，不用就删掉这一段--
item_handler[80124] = function(user, item_id)
	local list1 = {22001, 22003} -- 可以回收的装备id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收装备列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 9, 16, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装备后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收装备： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("装备栏第一行无符合回收条件的装备", 14)
    end
end
--以下为装备回收，不用就删掉这一段--
item_handler[80125] = function(user, item_id)
	local list1 = {22001, 22003} -- 可以回收的装备id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收装备列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 9, 16, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装备后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收装备： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("装备栏第一行无符合回收条件的装备", 14)
    end
end

--以下为宠物回收，不用就删掉这一段--
item_handler[80126] = function(user, item_id)
	local list1 = {3001305, 3001306} -- 可以回收的宠物id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收宠物列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))

    for i = 0, 6, 1 do
        local info = dpx.item.info(user.cptr, 7, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个宠物后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, 7, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收宠物： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("宠物栏第一行无符合回收条件的宠物", 14)
    end
end
--以下为宠物回收，不用就删掉这一段--
item_handler[80127] = function(user, item_id)
	local list1 = {3001305, 3001306} -- 可以回收的宠物id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收宠物列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))

    for i = 0, 6, 1 do
        local info = dpx.item.info(user.cptr, 7, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个宠物后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, 7, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收宠物： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("宠物栏第一行无符合回收条件的宠物", 14)
    end
end
--以下为宠物回收，不用就删掉这一段--
item_handler[80128] = function(user, item_id)
	local list1 = {3001305, 3001306} -- 可以回收的宠物id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收宠物列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))

    for i = 0, 6, 1 do
        local info = dpx.item.info(user.cptr, 7, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个宠物后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, 7, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收宠物： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("宠物栏第一行无符合回收条件的宠物", 14)
    end
end
--以下为宠物回收，不用就删掉这一段--
item_handler[80129] = function(user, item_id)
	local list1 = {3001305, 3001306} -- 可以回收的宠物id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收宠物列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))

    for i = 0, 6, 1 do
        local info = dpx.item.info(user.cptr, 7, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个宠物后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, 7, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收宠物： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("宠物栏第一行无符合回收条件的宠物", 14)
    end
end
--以下为宠物回收，不用就删掉这一段--
item_handler[80130] = function(user, item_id)
	local list1 = {3001305, 3001306} -- 可以回收的宠物id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收宠物列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))

    for i = 0, 6, 1 do
        local info = dpx.item.info(user.cptr, 7, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个宠物后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, 7, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收宠物： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("宠物栏第一行无符合回收条件的宠物", 14)
    end
end

--以下为宠物装备回收，不用就删掉这一段--
item_handler[80131] = function(user, item_id)
	local list1 = {63505, 63502} -- 可以回收的宠物装备id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收宠物装备列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 140, 146, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.CREATURE, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装备后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, game.ItemSpace.CREATURE, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收宠物装备： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("宠物装备栏第一行无符合回收条件的宠物装备", 14)
    end
end
--以下为宠物装备回收，不用就删掉这一段--
item_handler[80132] = function(user, item_id)
	local list1 = {63505, 63502} -- 可以回收的宠物装备id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收宠物装备列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 140, 146, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.CREATURE, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装备后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, game.ItemSpace.CREATURE, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收宠物装备： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("宠物装备栏第一行无符合回收条件的宠物装备", 14)
    end
end
--以下为宠物装备回收，不用就删掉这一段--
item_handler[80133] = function(user, item_id)
	local list1 = {63505, 63502} -- 可以回收的宠物装备id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收宠物装备列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 140, 146, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.CREATURE, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装备后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, game.ItemSpace.CREATURE, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收宠物装备： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("宠物装备栏第一行无符合回收条件的宠物装备", 14)
    end
end
--以下为宠物装备回收，不用就删掉这一段--
item_handler[80134] = function(user, item_id)
	local list1 = {63505, 63502} -- 可以回收的宠物装备id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收宠物装备列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 140, 146, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.CREATURE, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装备后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, game.ItemSpace.CREATURE, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收宠物装备： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("宠物装备栏第一行无符合回收条件的宠物装备", 14)
    end
end
--以下为宠物装备回收，不用就删掉这一段--
item_handler[80135] = function(user, item_id)
	local list1 = {63505, 63502} -- 可以回收的宠物装备id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收宠物装备列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 140, 146, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.CREATURE, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装备后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, game.ItemSpace.CREATURE, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收宠物装备： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("宠物装备栏第一行无符合回收条件的宠物装备", 14)
    end
end

--以下为装扮回收，不用就删掉这一段--
item_handler[80136] = function(user, item_id)
	local list1 = {2170007, 2170013} -- 可以回收的装扮id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收装扮列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 0, 6, 1 do
        local info = dpx.item.info(user.cptr, 1, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装扮后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, 1, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收装扮： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("装扮栏第一行无符合回收条件的装扮", 14)
    end
end
--以下为装扮回收，不用就删掉这一段--
item_handler[80137] = function(user, item_id)
	local list1 = {2170007, 2170013} -- 可以回收的装扮id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收装扮列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 0, 6, 1 do
        local info = dpx.item.info(user.cptr, 1, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装扮后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, 1, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收装扮： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("装扮栏第一行无符合回收条件的装扮", 14)
    end
end
--以下为装扮回收，不用就删掉这一段--
item_handler[80138] = function(user, item_id)
	local list1 = {2170007, 2170013} -- 可以回收的装扮id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收装扮列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 0, 6, 1 do
        local info = dpx.item.info(user.cptr, 1, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装扮后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, 1, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收装扮： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("装扮栏第一行无符合回收条件的装扮", 14)
    end
end
--以下为装扮回收，不用就删掉这一段--
item_handler[80139] = function(user, item_id)
	local list1 = {2170007, 2170013} -- 可以回收的装扮id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收装扮列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 0, 6, 1 do
        local info = dpx.item.info(user.cptr, 1, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装扮后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, 1, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收装扮： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("装扮栏第一行无符合回收条件的装扮", 14)
    end
end
--以下为装扮回收，不用就删掉这一段--
item_handler[80140] = function(user, item_id)
	local list1 = {2170007, 2170013} -- 可以回收的装扮id
    local list2 = {3037, 3033} -- 回收奖励id
    local to_recycle = {} -- 待回收装扮列表
	local q = 0
    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
    
    for i = 0, 6, 1 do
        local info = dpx.item.info(user.cptr, 1, i)
        if info then
            for _, _equip in ipairs(list1) do
                if info.id == _equip then
                    table.insert(to_recycle, i)
                    
                    -- 在每回收一个装扮后奖励一次
                    local n = math.random(1, #list2)
                    local count = math.random(1, 5)
                    dpx.item.add(user.cptr, list2[n], count)
                    dpx.item.delete(user.cptr, 1, i, 1)
                    q = q + 1
                    break
                end
            end
        end
    end
	
    user:SendNotiPacketMessage(string.format("已回收装扮： %s个", q), 14)
	
    if #to_recycle == 0 then
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("装扮栏第一行无符合回收条件的装扮", 14)
    end
end

--以下为宠物合成，不用就删掉这一段--
item_handler[80141] = function(user, item_id)
    -- 定义五阶宠物ID，0、1、2、3、4区分品阶(稀有、神器、传说、史诗、神话) 
    local pet_map = {
        [63043] =  0,
        [63079] =  1,
        [63089] =  2,
        [63013] =  3,
        [63014] =  4,
    }


    local pet_item1 = dpx.item.info(user.cptr, 7, 0)-- 获取背包中宠物第一格的信息
    local pet_item2 = dpx.item.info(user.cptr, 7, 1)-- 获取背包中宠物第二格的信息
    if pet_item1 and pet_item2 then
        local pet_id1 = pet_item1.id
        local pet_id2 = pet_item2.id
        local num1 = pet_map[pet_id1]
        local num2 = pet_map[pet_id2]
        if num1 and  num2  then
                    --前四阶宠物0,1,2,3 的合成概率分别为0.1,0.11，0.12,0.13 例如 0（稀有）+1（神器）的合成概率为0.3
            local prob = 0.1 * (num1 == 0 and 1 or 0) +0.1 * (num2 == 0 and 1 or 0) -- 计算0的概率
            + 0.11 * (num1 == 1 and 1 or 0) + 0.11 *(num2 == 1 and 1 or 0) -- 计算1的概率
            + 0.12 * (num1 == 2 and 1 or 0) + 0.12 * (num2 == 2 and 1 or 0) -- 计算2的概率
            + 0.13 * (num1 == 3 and 1 or 0) + 0.13 *(num2 == 3 and 1 or 0) -- 计算3的概率
	    math.randomseed(tostring(os.time()):reverse():sub(1, 7))
            local rand = math.random() -- 生成一个 0~1 的随机数
       	    local math_max = require("math").max
            finalnum = math_max(num1,num2) + 1

            if finalnum <= 4 then
                if rand <= prob then -- 如果随机数小于等于概率，则合成成功
                    local finalpets = {}--保存高品阶宠物ID
                    for k, val in pairs (pet_map) do
                        if val == finalnum then
                            table.insert(finalpets, k)
                        end
                    end
                    -- 删除背包中的宠物
                    dpx.item.delete(user.cptr, 7, 0, 1)
                    dpx.item.delete(user.cptr, 7, 1, 1)
                    dpx.item.add(user.cptr, finalpets[math.random(1, #finalpets)], 1) --获得随机一个高品阶宠物
                    user:SendNotiPacketMessage("合成成功，已获得更高级宠物", 14)
                else -- 否则合成失败，仅保留第一格宠物！
                    dpx.item.delete(user.cptr, 7, 1, 1)
                    user:SendNotiPacketMessage("合成失败，仅保留第一格宠物", 14)
                end
            else
                dpx.item.add(user.cptr, item_id)
                user:SendNotiPacketMessage("已是最高阶宠物，无法合成", 14)    
            end
        else
            -- 回收券返回背包
            dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("请确保宠物栏前二格宠物符合合成条件", 14)
        end
    else
        dpx.item.add(user.cptr, item_id)
        user:SendNotiPacketMessage("请确保宠物栏前二格都有宠物", 14)
    end
end

--以下为分解装备前两行，需自身开分解机，不用就删掉这一段--
item_handler[80142] = function(user, item_id)
    local q = 0
	for i = 9, 24, 1 do
		local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
		if info then
            user:Disjoint(game.ItemSpace.INVENTORY, i, user)
            if not dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i) then
                q = q + 1
            end
		end
	end
    if q > 0 then
        user:SendItemSpace(game.ItemSpace.INVENTORY)
        user:SendNotiPacketMessage(string.format("分解成功， %d件装备已分解", q), 14)
    else
        user:SendNotiPacketMessage("分解失败，", 14)
        dpx.item.add(user.cptr, item_id)
    end
end

--以下为删除装备栏前两行的装备，不用就删掉这一段--
item_handler[80143] = function(user, item_id)
    local q = 0
    for i = 9, 24, 1 do
        local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, i)
        if info then
			dpx.item.delete(user.cptr, game.ItemSpace.INVENTORY, i, 1)
            q = q +1
        end
    end
    if q > 0 then
        user:SendItemSpace(game.ItemSpace.INVENTORY)
        user:SendNotiPacketMessage(string.format("清理成功，%d个装备已清理", q), 14)
    else
        user:SendNotiPacketMessage("清理失败，装备栏前两行为空", 14)
    end
end

--以下为删除宠物栏前两行的宠物，不用就删掉这一段--
item_handler[80144] = function(user, item_id)
    local q = 0
    for i = 0, 13, 1 do
        local info = dpx.item.info(user.cptr, 7, i)
        if info then
			dpx.item.delete(user.cptr, 7, i, 1)
            q = q +1
        end
    end
    if q > 0 then
        user:SendItemSpace(7)
        user:SendNotiPacketMessage(string.format("清理成功，%d个宠物已清理", q), 14)
    else
        user:SendNotiPacketMessage("清理失败，宠物栏前两行为空", 14)
    end
end

--以下为删除装扮栏的前两行，不用就删掉这一段--
item_handler[80145] = function(user, item_id)
    local q = 0
	for i = 0, 13, 1 do
		local info = dpx.item.info(user.cptr, 1, i)
		if info then
			dpx.item.delete(user.cptr, 1, i, 1)
            q = q + 1
		end
	end
    if q > 0 then
        user:SendItemSpace(1)
        user:SendNotiPacketMessage(string.format("清理成功，%d件装扮已清理", q), 14)
    else
        user:SendNotiPacketMessage("清理失败，装扮栏前两行为空", 14)
    end
end

--以下为悬赏令任务，不用就删掉这一段--
item_handler[80146] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80147] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80148] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80149] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80150] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80151] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80152] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80153] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80154] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80155] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80156] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80157] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80158] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80159] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80160] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80161] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80162] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80163] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80164] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end
--以下为悬赏令任务，不用就删掉这一段--
item_handler[80165] = function(user, item_id)
    local ok = dpx.quest.accept(user.cptr, 94, true)
    user:SendNotiPacketMessage("悬赏令任务已接取", 14)
    if not ok then
        dpx.item.add(user.cptr, item_id)
		user:SendNotiPacketMessage("无可接取任务", 14)
    end
end

--以下为无限制装备继承，装备栏第一个装备的强化/增幅、附魔、锻造、魔法封印(未实现)转移到装备栏第二个的装备上，不用就删掉这一段--
item_handler[80166] = function(user, item_id)
    local mask = game.InheritMask.FLAG_UPGRADE | game.InheritMask.FLAG_AMPLIFY | game.InheritMask.FLAG_ENCHANT | game.InheritMask.FLAG_SEPARATE
    mask = mask | game.InheritMask.FLAG_MOVE_UPGRADE | game.InheritMask.FLAG_MOVE_AMPLIFY | game.InheritMask.FLAG_MOVE_ENCHANT | game.InheritMask.FLAG_MOVE_SEPARATE

    local item1 = dpx.item.info(user, game.ItemSpace.INVENTORY, 9)
    local item2 = dpx.item.info(user, game.ItemSpace.INVENTORY, 10)

    if item1 == nil or item2 == nil then
        user:SendNotiPacketMessage("转移失败，装备栏第一格或第二格无正确装备", 14)
    elseif dpx.item.inherit(user.cptr, 9, 10, mask) then
        return user:SendNotiPacketMessage(string.format("所有数据 已从: 【%s】\n       转至: 【%s】", item1.name, item2.name), 14)
    end
    dpx.item.add(user.cptr, item_id)
end
--以下为有限制装备继承，装备栏第一个装备的强化/增幅、附魔、锻造、魔法封印(未实现)转移到装备栏第二个的装备上，不用就删掉这一段--
item_handler[80167] = function(user, item_id)
    local mask = game.InheritMask.FLAG_UPGRADE | game.InheritMask.FLAG_AMPLIFY | game.InheritMask.FLAG_ENCHANT | game.InheritMask.FLAG_SEPARATE
    mask = mask | game.InheritMask.FLAG_MOVE_UPGRADE | game.InheritMask.FLAG_MOVE_AMPLIFY | game.InheritMask.FLAG_MOVE_ENCHANT | game.InheritMask.FLAG_MOVE_SEPARATE

    local item1 = dpx.item.info(user, game.ItemSpace.INVENTORY, 9)
    local item2 = dpx.item.info(user, game.ItemSpace.INVENTORY, 10)

    if item1 == nil or item2 == nil then
        user:SendNotiPacketMessage("转移失败，装备栏第一格或第二格无正确装备", 14)
    elseif item1.type ~= item2.type then
        user:SendNotiPacketMessage("转移失败，装备栏前两格装备类型不同", 14)
    elseif item1.rarity ~= item2.rarity  then
        user:SendNotiPacketMessage("转移失败，装备栏前两格装备品级不同", 14)
    elseif math.abs(item2.usable_level - item1.usable_level) >5 then
        user:SendNotiPacketMessage("转移失败，装备栏前两格装备等级差距超过5级", 14)
    elseif item1.usable_level < 50 or item2.usable_level < 50   then
        user:SendNotiPacketMessage("转移失败，装备栏第一格或第二格装备低于50级", 14)
    elseif item1.amplify.type == 0 and item2.amplify.type ~= 0  then
        user:SendNotiPacketMessage("转移失败，强化装备无法继承至增幅装备", 14)
    elseif dpx.item.inherit(user.cptr, 9, 10, mask) then
        return user:SendNotiPacketMessage(string.format("所有数据 已从: 【%s】\n       转至: 【%s】", item1.name, item2.name), 14)
    end
    dpx.item.add(user.cptr, item_id)
end
--以下为有限制装备继承，装备栏第一个装备的附魔转移到装备栏第二个的装备上，不用就删掉这一段--
item_handler[80168] = function(user, item_id)
    local mask = game.InheritMask.FLAG_ENCHANT
    mask = mask | game.InheritMask.FLAG_MOVE_ENCHANT

    local item1 = dpx.item.info(user, game.ItemSpace.INVENTORY, 9)
    local item2 = dpx.item.info(user, game.ItemSpace.INVENTORY, 10)

    if item1 == nil or item2 == nil then
        user:SendNotiPacketMessage("转移失败，装备栏第一格或第二格无正确装备", 14)
    elseif item1.type ~= item2.type then
        user:SendNotiPacketMessage("转移失败，装备栏前两格装备类型不同", 14)
    elseif dpx.item.inherit(user.cptr, 9, 10, mask) then
        return user:SendNotiPacketMessage(string.format("附魔数据 已从: 【%s】\n       转至: 【%s】", item1.name, item2.name), 14)
    end
    dpx.item.add(user.cptr, item_id)
end
--以下为有限制装备继承，装备栏第一个装备的锻造转移到装备栏第二个的装备上，不用就删掉这一段--
item_handler[80169] = function(user, item_id)
    local mask = game.InheritMask.FLAG_SEPARATE
    mask = mask | game.InheritMask.FLAG_MOVE_SEPARATE

    local item1 = dpx.item.info(user, game.ItemSpace.INVENTORY, 9)
    local item2 = dpx.item.info(user, game.ItemSpace.INVENTORY, 10)

    if item1 == nil or item2 == nil then
        user:SendNotiPacketMessage("转移失败，装备栏第一格或第二格无正确装备", 14)
    elseif item1.type ~= item2.type then
        user:SendNotiPacketMessage("转移失败，装备栏前两格装备类型不同", 14)
    elseif item1.rarity ~= item2.rarity  then
        user:SendNotiPacketMessage("转移失败，装备栏前两格装备品级不同", 14)
    elseif math.abs(item2.usable_level - item1.usable_level) > 5 then
        user:SendNotiPacketMessage("转移失败，装备栏前两格装备等级差距超过5级", 14)
    elseif dpx.item.inherit(user.cptr, 9, 10, mask) then
        return user:SendNotiPacketMessage(string.format("锻造数据 已从: 【%s】\n       转至: 【%s】", item1.name, item2.name), 14)
    end
    dpx.item.add(user.cptr, item_id)
end
--以下为有限制装备继承，装备栏第一个装备的魔法封印(未实现)转移到装备栏第二个的装备上，不用就删掉这一段--
--item_handler[80170] = function(user, item_id)

--以下为1000点券增加券（不用就删掉这一大段）!
item_handler[80171] = function(user, item_id)
    local cera_count = 1000
    user:ChargeCera(cera_count)
    user:SendNotiPacketMessage(string.format("已充值%d点券！", cera_count), 14)
    local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
           	local logMsg = string.format("%s	%d	%s	道具充值	点券	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), cera_count)
           	logFile:write(logMsg)  
           	logFile:close()  
       	end	
end
--以下为2000点券增加券（不用就删掉这一大段）!
item_handler[80172] = function(user, item_id)
    local cera_count = 2000
    user:ChargeCera(cera_count)
    user:SendNotiPacketMessage(string.format("已充值%d点券！", cera_count), 14)
    local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
           	local logMsg = string.format("%s	%d	%s	道具充值	点券	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), cera_count)
           	logFile:write(logMsg)  
           	logFile:close()  
       	end	
end
--以下为5000点券增加券（不用就删掉这一大段）!
item_handler[80173] = function(user, item_id)
    local cera_count = 5000
    user:ChargeCera(cera_count)
    user:SendNotiPacketMessage(string.format("已充值%d点券！", cera_count), 14)
    local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
           	local logMsg = string.format("%s	%d	%s	道具充值	点券	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), cera_count)
           	logFile:write(logMsg)  
           	logFile:close()  
       	end	
end
--以下为10000点券增加券（不用就删掉这一大段）!
item_handler[80174] = function(user, item_id)
    local cera_count = 10000
    user:ChargeCera(cera_count)
    user:SendNotiPacketMessage(string.format("已充值%d点券！", cera_count), 14)
    local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
           	local logMsg = string.format("%s	%d	%s	道具充值	点券	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), cera_count)
           	logFile:write(logMsg)  
           	logFile:close()  
       	end	
end
--以下为20000点券增加券（不用就删掉这一大段）!
item_handler[80175] = function(user, item_id)
    local cera_count = 20000
    user:ChargeCera(cera_count)
    user:SendNotiPacketMessage(string.format("已充值%d点券！", cera_count), 14)
    local logFile = io.open("/dp2/script/rizhi.log", "a")  
   		if logFile then
           	local logMsg = string.format("%s	%d	%s	道具充值	点券	%s\n", os.date("%Y-%m-%d %H:%M:%S"), user:GetAccId(), user:GetCharacName(), cera_count)
           	logFile:write(logMsg)  
           	logFile:close()  
       	end	
end

--以下为决斗等级+1，不用就删掉这一段--
item_handler[80176] = function(user, item_id)
    dpx.sqlexec(game.DBType.taiwan_cain, "update taiwan_cain.pvp_result set pvp_grade=pvp_grade+1 where charac_no=" .. user:GetCharacNo() .. "")
	user:SendNotiPacketMessage("决斗等级：+1，请切换角色以生效", 14)
end
--以下为决斗等级-1，不用就删掉这一段--
item_handler[80177] = function(user, item_id)
    dpx.sqlexec(game.DBType.taiwan_cain, "update taiwan_cain.pvp_result set pvp_grade=pvp_grade-1 where charac_no=" .. user:GetCharacNo() .. "")
	user:SendNotiPacketMessage("决斗等级：-1，请切换角色以生效", 14)
end
--以下为决斗经验+1000，不用就删掉这一段--
item_handler[80178] = function(user, item_id)
    dpx.sqlexec(game.DBType.taiwan_cain, "update taiwan_cain.pvp_result set pvp_point=pvp_point+1000 where charac_no=" .. user:GetCharacNo() .. "")
	user:SendNotiPacketMessage("决斗经验：+1000，请切换角色以生效", 14)
end
--以下为决斗经验-1000，不用就删掉这一段--
item_handler[80179] = function(user, item_id)
    dpx.sqlexec(game.DBType.taiwan_cain, "update taiwan_cain.pvp_result set pvp_point=pvp_point-1000 where charac_no=" .. user:GetCharacNo() .. "")
	user:SendNotiPacketMessage("决斗经验：-1000，请切换角色以生效", 14)
end
--以下为决斗胜点+10，不用就删掉这一段--
item_handler[80180] = function(user, item_id)
    dpx.sqlexec(game.DBType.taiwan_cain, "update taiwan_cain.pvp_result set win_point=win_point+10 where charac_no=" .. user:GetCharacNo() .. "")
	user:SendNotiPacketMessage("决斗胜点：+10，请切换角色以生效", 14)
end

--以下为转职券，转职成大职业中的1号小职业，不用就删掉这一段--
item_handler[80181] = function(user, item_id)
	local level = user:GetCharacLevel()
    local growType = user:GetCharacGrowType()
        if growType > 6 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("转职失败，必须是未觉醒职业", 14)
        elseif level < 15 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("转职失败，Lv15角色才能转职", 14)
		else user:ChangeGrowType(1, 0)
		    user:SendNotiPacketMessage("转职成功，请切换角色并初始化SP", 14)
        end
end
--以下为转职券，转职成大职业中的2号小职业，不用就删掉这一段--
item_handler[80182] = function(user, item_id)
	local level = user:GetCharacLevel()
    local growType = user:GetCharacGrowType()
        if growType > 6 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("转职失败，必须是未觉醒职业", 14)
        elseif level < 15 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("转职失败，Lv15角色才能转职", 14)
		else user:ChangeGrowType(2, 0)
		    user:SendNotiPacketMessage("转职成功，请切换角色并初始化SP", 14)
        end
end
--以下为转职券，转职成大职业中的3号小职业，不用就删掉这一段--
item_handler[80183] = function(user, item_id)
	local level = user:GetCharacLevel()
    local growType = user:GetCharacGrowType()
        if growType > 6 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("转职失败，必须是未觉醒职业", 14)
        elseif level < 15 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("转职失败，Lv15角色才能转职", 14)
		else user:ChangeGrowType(3, 0)
		    user:SendNotiPacketMessage("转职成功，请切换角色并初始化SP", 14)
        end
end
--以下为转职券，转职成大职业中的4号小职业，不用就删掉这一段--
item_handler[80184] = function(user, item_id)
	local level = user:GetCharacLevel()
    local growType = user:GetCharacGrowType()
        if growType > 6 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("转职失败，必须是未觉醒职业", 14)
        elseif level < 15 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("转职失败，Lv15角色才能转职", 14)
		else user:ChangeGrowType(4, 0)
		    user:SendNotiPacketMessage("转职成功，请切换角色并初始化SP", 14)
        end
end
--以下为转职券，转职成大职业中的5号小职业，不用就删掉这一段--
item_handler[80185] = function(user, item_id)
	local level = user:GetCharacLevel()
    local growType = user:GetCharacGrowType()
        if growType > 6 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("转职失败，必须是未觉醒职业", 14)
        elseif level < 15 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("转职失败，Lv15角色才能转职", 14)
		else user:ChangeGrowType(5, 0)
		    user:SendNotiPacketMessage("转职成功，请切换角色并初始化SP", 14)
        end
end
--以下为转职券，转职成大职业中的0号小职业，不用就删掉这一段--
item_handler[80186] = function(user, item_id)
	local level = user:GetCharacLevel()
    local growType = user:GetCharacGrowType()
        if growType > 6 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("转职失败，必须是未觉醒职业", 14)
        elseif level < 15 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("转职失败，Lv15角色才能转职", 14)
		else user:ChangeGrowType(0, 0)
		    user:SendNotiPacketMessage("转职成功，请切换角色并初始化SP", 14)
        end
end

--以下为一次觉醒券，不用就删掉这一段--
item_handler[80187] = function(user, item_id)
	local level = user:GetCharacLevel()
    local growType = user:GetCharacGrowType()
        if growType > 6 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("一觉失败，必须是未觉醒职业", 14)
        elseif level < 48 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("一觉失败，Lv48角色才能觉醒", 14)
		else user:ChangeGrowType(growType, 1)
		    user:SendNotiPacketMessage("一觉成功", 14)
        end
end

--以下为二次觉醒券，不用就删掉这一段--
item_handler[80188] = function(user, item_id)
	local level = user:GetCharacLevel()
    local growType = user:GetCharacGrowType()
        if growType < 16 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("二觉失败，必须是一觉职业", 14)
        elseif level > 69 then
		    dpx.item.add(user.cptr, item_id)
            user:SendNotiPacketMessage("二觉失败，Lv70角色才能二觉", 14)
		else user:ChangeGrowType(growType, 1)
		    user:SendNotiPacketMessage("二觉成功", 14)
        end
end

--命运之书[80189] 代码写法在dp2\df_game_r.js中2176行--

--以下为角色变更为鬼剑士，不用就删掉这一段--
item_handler[80190] = function(user, item_id)
        user:ChangeGrowType(0, 0)
		dpx.sqlexec(game.DBType.taiwan_cain, "update charac_info set job=0 where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage("变更成功，请切换角色以生效并在切换后初始化SP", 14)
end
--以下为角色变更为女格斗，不用就删掉这一段--
item_handler[80191] = function(user, item_id)
        user:ChangeGrowType(0, 0)
		dpx.sqlexec(game.DBType.taiwan_cain, "update charac_info set job=1 where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage("变更成功，请切换角色以生效并在切换后初始化SP", 14)
end
--以下为角色变更为男枪手，不用就删掉这一段--
item_handler[80192] = function(user, item_id)
        user:ChangeGrowType(0, 0)
		dpx.sqlexec(game.DBType.taiwan_cain, "update charac_info set job=2 where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage("变更成功，请切换角色以生效并在切换后初始化SP", 14)
end
--以下为角色变更为女法师，不用就删掉这一段--
item_handler[80193] = function(user, item_id)
        user:ChangeGrowType(0, 0)
		dpx.sqlexec(game.DBType.taiwan_cain, "update charac_info set job=3 where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage("变更成功，请切换角色以生效并在切换后初始化SP", 14)
end
--以下为角色变更为圣职者，不用就删掉这一段--
item_handler[80194] = function(user, item_id)
        user:ChangeGrowType(0, 0)
		dpx.sqlexec(game.DBType.taiwan_cain, "update charac_info set job=4 where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage("变更成功，请切换角色以生效并在切换后初始化SP", 14)
end
--以下为角色变更为女枪手，不用就删掉这一段--
item_handler[80195] = function(user, item_id)
        user:ChangeGrowType(0, 0)
		dpx.sqlexec(game.DBType.taiwan_cain, "update charac_info set job=5 where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage("变更成功，请切换角色以生效并在切换后初始化SP", 14)
end
--以下为角色变更为暗夜使者，不用就删掉这一段--
item_handler[80196] = function(user, item_id)
        user:ChangeGrowType(0, 0)
		dpx.sqlexec(game.DBType.taiwan_cain, "update charac_info set job=6 where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage("变更成功，请切换角色以生效并在切换后初始化SP", 14)
end
--以下为角色变更为男格斗，不用就删掉这一段--
item_handler[80197] = function(user, item_id)
        user:ChangeGrowType(0, 0)
		dpx.sqlexec(game.DBType.taiwan_cain, "update charac_info set job=7 where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage("变更成功，请切换角色以生效并在切换后初始化SP", 14)
end
--以下为角色变更为男法师，不用就删掉这一段--
item_handler[80198] = function(user, item_id)
        user:ChangeGrowType(0, 0)
		dpx.sqlexec(game.DBType.taiwan_cain, "update charac_info set job=8 where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage("变更成功，请切换角色以生效并在切换后初始化SP", 14)
end
--以下为角色变更为黑暗武士，不用就删掉这一段--
item_handler[80199] = function(user, item_id)
        user:ChangeGrowType(0, 0)
		dpx.sqlexec(game.DBType.taiwan_cain, "update charac_info set job=9 where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage("变更成功，请切换角色以生效并在切换后初始化SP", 14)
end
--以下为角色变更为缔造者，不用就删掉这一段--
item_handler[80200] = function(user, item_id)
        user:ChangeGrowType(0, 0)
		dpx.sqlexec(game.DBType.taiwan_cain, "update charac_info set job=10 where charac_no=" .. user:GetCharacNo() .. "")
        user:SendNotiPacketMessage("变更成功，请切换角色以生效并在切换后初始化SP", 14)
end

--以下为装备跨界，不用就删掉这一段--
item_handler[80201] = function(user, item_id)
    local list = {840000, 840001} -- 不可转移的装备代码
    local boolx = false
    local info = dpx.item.info(user.cptr, game.ItemSpace.INVENTORY, 9)
    if info then
        for _, _equip in pairs(list) do
            if info.id == _equip then
                boolx = true
                break
            end
        end
        if not boolx then
            if not user:MoveToAccCargo(game.ItemSpace.INVENTORY, 9) then
                user:SendNotiPacketMessage("跨界失败，请确保共享仓库有空余位置", 14)
                dpx.item.add(user.cptr, item_id)
            else
                user:SendNotiPacketMessage(string.format("跨界成功，【%s】已转移至共享仓库", info.name), 14)
            end
        end
        if boolx then
            dpx.item.add(user.cptr, item_id, 1)
            user:SendNotiPacketMessage("跨界失败，该物品不可转移", 14)
        end
    else
        dpx.item.add(user.cptr, item_id, 1)
        user:SendNotiPacketMessage("跨界失败，装备栏第一格无装备", 14)
    end
end

--以下为异界次数重置，不用就删掉这一段--
item_handler[80202] = function(user, item_id)
    user:ResetDimensionInout(0)
    user:ResetDimensionInout(1)
    user:ResetDimensionInout(2)
    user:SendNotiPacketMessage("E2入场次数已重置", 14)
end
item_handler[80203] = function(user, item_id)
    user:ResetDimensionInout(3)
    user:ResetDimensionInout(4)
    user:ResetDimensionInout(5)
    user:SendNotiPacketMessage("E3入场次数已重置", 14)
end

--以下为角色设计图熟练度，不用就删掉这一段--
item_handler[80204] = function(user, item_id)
    dpx.sqlexec(game.DBType.taiwan_cain, "INSERT INTO item_making_skill_info (charac_no, weapon, cloth, leather, light_armor, heavy_armor, plate, amulet, wrist, ring, support, magic_stone) VALUES (" .. user:GetCharacNo() .. ", 140, 140, 140, 140, 140, 140, 140, 140, 140, 140, 140) ON DUPLICATE KEY UPDATE weapon = VALUES(weapon),cloth = VALUES(cloth), leather = VALUES(leather), light_armor = VALUES(light_armor), heavy_armor = VALUES(heavy_armor), plate = VALUES(plate), amulet = VALUES(amulet), wrist = VALUES(wrist), ring = VALUES(ring), support = VALUES(support), magic_stone = VALUES(magic_stone)")
    user:SendNotiPacketMessage("角色装备设计图熟练度提升成功", 14)
end

--以下为佣兵出战券，不用就删掉这一段--
item_handler[80205] = function(user, item_id)
    local level = user:GetCharacLevel()
    if level == 1 then
        dpx.sqlexec(game.DBType.taiwan_cain, "UPDATE charac_link_bonus SET `exp`=0, gold=0, mercenary_start_time=UNIX_TIMESTAMP(), mercenary_finish_time=UNIX_TIMESTAMP()+10, mercenary_area=5, mercenary_period=4 WHERE charac_no=" .. user:GetCharacNo())
        user:SendNotiPacketMessage("角色出战成功，6小时后可领取奖励", 14)
    else
        user:SendNotiPacketMessage("角色出战失败，只有1级角色才能出战", 14)
        dpx.item.add(user.cptr, item_id)
    end
end

--[80206] 见120行 背包内有此道具 才能进入某副本--

--[80207] 见160行 背包内有此道具 挑战低级副本时 不限制掉落--

--[80208] 见172行 背包内有此道具 强化/增幅失败时 再次判定 若通过强制成功 反之仍然失败--

--以下为副本难度全开，不用就删掉这一段--
item_handler[80209] = function(user, item_id)
    dpx.sqlexec(game.DBType.taiwan_cain, "update member_dungeon set dungeon='2|3,3|3,4|3,5|3,6|3,7|3,8|3,9|3,11|3,12|3,13|3,14|3,15|3,17|3,21|3,22|3,23|3,24|3,25|3,26|3,27|3,31|3,32|3,33|3,34|3,35|3,36|3,37|3,40|3,42|3,43|3,44|3,45|3,50|3,51|3,52|3,53|3,60|3,61|3,65|2,66|1,67|2,70|3,71|3,72|3,73|3,74|3,75|3,76|3,77|3,80|3,81|3,82|3,83|3,84|3,85|3,86|3,87|3,88|3,89|3,90|3,91|2,92|3,93|3,100|3,101|3,102|3,103|3,104|3,110|3,111|3,112|3,140|3,141|3,502|3,511|3,521|3,1000|3,1500|3,1501|3,1502|3,1504|1,1506|3,3506|3,10000|3' where m_id=" .. user:GetAccId() .. "")
    user:SendNotiPacketMessage("已开启账号副本难度", 14)
end

--以下为角色栏位增至24格，不用就删掉这一段--
item_handler[80210] = function(user, item_id)
    user:SetCharacSlotLimit(24)
    user:SendNotiPacketMessage("角色栏数量已开启至24个", 14)
end

--以下为SP技能书，不用就删掉这一段--
item_handler[80211] = function(user, item_id)
	local x = 1000
    dpx.sqlexec(game.DBType.taiwan_cain_2nd, "update skill set remain_sp=remain_sp+" .. x .. " where charac_no=" .. user:GetCharacNo() .. "")
    user:SendNotiPacketMessage(string.format("已充值%d SP，请切换角色以生效", x), 14)
end

--以下为TP技能书，不用就删掉这一段--
item_handler[80212] = function(user, item_id)
	local x = 20
    dpx.sqlexec(game.DBType.taiwan_cain_2nd, "update skill set remain_sfp_1st=remain_sfp_1st+" .. x .. " where charac_no=" .. user:GetCharacNo() .. "")
    user:SendNotiPacketMessage(string.format("已充值%d TP，请切换角色以生效", x), 14)
end

--以下为QP技能书，不用就删掉这一段--
item_handler[80213] = function(user, item_id)
	local x = 1000
    dpx.sqlexec(game.DBType.taiwan_cain, "update charac_quest_shop set qp=qp+" .. x .. " where charac_no=" .. user:GetCharacNo() .. "")
    user:SendNotiPacketMessage(string.format("已充值%d QP，请切换角色以生效", x), 14)
end

--副职业变更书[80216] 未实现--
--副职业变更书[80217] 未实现--
--副职业变更书[80218] 未实现--
--副职业变更书[80219] 未实现--
--副职业满级书[80220] 未实现--
--绝望之塔跳层书[80221] 未实现--


----------------------------------------------------------------------------道具结束----------------------------------------------------------------------------



-------------------------- 以下代码使用上方子程序功能的启动代码[前面加了--是代表不生效的意思，如需要某项功能，删除前面的--即可]----------------------------------
dpx.open_timegate()--时空之门开门什么的
dpx.hook(game.HookType.GmInput, on_input)--对于游戏内输入指令反馈和结果
dpx.hook(game.HookType.UseItem2, my_useitem2)-- 跨界石、升级券、任务清理券、异界重置券、装备继承券、悬赏令任务hook !
--dpx.hook(game.HookType.GameEvent, myGameEvent)--必须有道具，才能进入副本！
--dpx.hook(game.HookType.CParty_DropItem, my_drop_item)-- 高等级刷低级图不掉落！
--dpx.hook(game.HookType.Upgrade, MyUpgrade)-- 强化或增幅必定成功！
dpx.hook(game.HookType.GameEvent, finishBackHome)

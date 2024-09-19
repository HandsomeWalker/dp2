local dp = _DP
local dpx = _DPX
local luv = require("luv")
local game = require("df.game")
local logger = require("df.logger")
local frida = require("df.frida")


---------------------------------- 以下代码是修复绝望之塔卡金币异常，不需要就删除-------------------------------- !
local function MyUseAncientDungeonItems(next, _party, _dungeon, _item)
    local party = game.fac.party(_party)
    local dungeon = game.fac.dungeon(_dungeon)

    local dungeon_index = dungeon:GetIndex()
    if dungeon_index >= 11008 and dungeon_index <= 11107 then
        return true
    end

    return next()
end

---------------------------------- 以下代码是城镇下线卡镇魂，不需要就删除-------------------------------- !
local my_save_town = function(_user, pre_town_id, post_town_id)
    if post_town_id == 13 then
        post_town_id = 11
    end

    return post_town_id
end

---------------------------------- 以下代码是开放极限祭坛，不需要就删除-------------------------------- !
local my_open_dungeon = function(next, dgn_idx)
    if (dgn_idx == 11007) then
        return true
    end

    return next(dgn_idx)
end

------------- 以下代码使用上方子程序功能的启动代码，不需要某个就删除--------------------- !
dpx.opt()
frida.load()-- 镶嵌、幸运值、深渊播报等！
dpx.set_max_level(90)-- 设置服务端等级上限 !
dp.mem.hotfix(dpx.reloc(0x0808A9D9 + 1), 1, 0xB6)-- 修复小明炸街 !
dpx.disable_item_routing()-- 史诗免确认提示框 !
dpx.disable_mobile_rewards()-- 新创建角色没有成长契约邮件 !
dpx.set_unlimit_towerofdespair()-- 绝望之塔通关后仍可继续挑战(需门票) !
dpx.enable_game_master()-- 开启GM模式(需把UID添加到GM数据库中) !
dpx.disable_trade_limit()-- 解除交易限额(已经达到上限的第二天生效) !
dpx.fix_auction_regist_item(200000000)-- 修复拍卖行消耗品上架最大总价, 建议值2E !
dpx.enable_creator()-- 开启创建缔造者接口，需要本地exe配合，建议0725 !
dpx.hook(game.HookType.CParty_UseAncientDungeonItems, MyUseAncientDungeonItems)-- 修复绝望之塔金币提示异常 !
dpx.hook(game.HookType.CUser_SaveTown, my_save_town)-- 修复原始服务端补丁下线卡镇魂城镇 !
dpx.hook(game.HookType.Open_Dungeon, my_open_dungeon)-- 开启极限祭坛副本 !
dpx.set_item_unlock_time(1)-- 设置装备解锁时间！
--dpx.disable_giveup_panalty()-- 退出副本后角色默认不虚弱 !
--dpx.set_auction_min_level(10)-- 设置使用拍卖行的最低等级！
--dpx.extend_teleport_item()---扩展移动瞬间药剂ID: 2600014/2680784/2749064！
--dpx.disable_redeem_item()-- 关闭NPC回购系统（禁用志愿兵） !
--dpx.disable_security_protection()-- 解除100级以及以上的限制 !

logger.info("opt: %s", dpx.opt())
-- see dp2/lua/df/doc for document !


------------- 以下为热加载Lua脚本，对于/dp2/script/Work_Reload.lua文件内的更改可以不需要五国--------------------- 
local lfs = require("lfs") --这个包用于检查脚本文件的时间戳
local filename = "/dp2/script/Work_Reload.lua" --要读取的文件
local filepacket --用来保存函数的变量

-- 创建一个新的 _ENV 变量表
local new_env = {}
--将Lua基础函数和全局环境包括进去 如果禁用这一条,会导致类似string  tonumber等基础Lua函数无法使用
setmetatable(new_env, {__index = _G}) 
--要共享的变量  注释掉的是尝试将本脚本全部变量导入,好像会出错?
--[[
for k, v in pairs(_G) do
    new_env[k] = v
end
]]
-- 与该文件共享的变量在这里添加,热加载的脚本会共享这些变量
-- 右边是当前脚本变量名 ,左边的new_env是表名.后面的是要传递给新脚本的变量名
-- 类似frida这种 多次重载会崩溃
new_env.frida = frida
-- 类似dpx dp game world logger 你需要继承这些来让新脚本能获取user表等东西
new_env.logger = logger
new_env.dp = dp
new_env.dpx = dpx
new_env.game = game
new_env.world = world
local luv = require("luv")
-- 类似item_handler你需要继承这些来让新脚本能获取在这个脚本创建的道具的钩子表
new_env.item_handler = item_handler

-- ↑为了方便存入这些变量,该热加载脚本最好放置在本脚本文件尾

local function reload_script()
  package.loaded[filename] = nil --清空导入包
  local ok, err = pcall(function()
  --将脚本文件的内容保存在变量filepacket编译为函数,并且导入环境变量表new_env
    filepacket = loadfile(filename,"t",new_env) 
end)
  if not ok then
	logger.info("读取文件-失败")
	logger.info("File:%s", err)
	else
	logger.info("读取文件-成功")
  end
  ok, err = pcall(filepacket) --执行脚本内容(成为函数后的filepacket)
  if not ok then
	logger.info("执行脚本-失败，请检查脚本内容是否出错!")
	logger.info("File:%s", err)
	else
	file_modification_time = lfs.attributes(filename, "modification")
	logger.info("执行脚本-成功，脚本内容已重新加载!")
  end
end

local function script_modified()
  if lfs.attributes(filename, "modification") ~= file_modification_time then --检测脚本文件时间戳
    reload_script()
  end
end

local file_modification_time --时间戳记录
local AutoTimer = luv.new_timer()
AutoTimer:start(10000, 5000, script_modified) --5000是刷新间隔5秒 10000是多久后开始执行
--file_modification_time = lfs.attributes(filename, "modification") -- 这是用来记录最初该文件的修改日期
--reload_script()  


--每隔多久检查一次文件是否被修改 1000为1秒

-----------------------------------------------------------以上为热加载Lua脚本
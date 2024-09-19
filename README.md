## 前提
游戏已经能跑出五服，能登陆

## 文件放置说明
dp2 整个文件夹，放在服务端根目录

## 启动方式
在启动dfgame命令行（常见一键端是 **run** 文件）中, 添加 **LD_PRELOAD** 启动参数，在频道前添加启动代码，两者中间有个空格，一般PK频道不需要加，
例如：
```shell
./df_game_r cain01 start &
```
变成
```shell
LD_PRELOAD=/dp2/libdp2pre.so ./df_game_r cain01 start &
```

重跑五服，后期一般只需编辑及上传script/work_reload，无需重跑五服
# RMOS 用户服务器 0.13.0

## 新增/修复

- 控制台首页加载提速：优先加载概览、矿场、矿机等关键数据并立即渲染，其余数据在后台加载，F5 刷新更快。
- 长时间离开后切回控制台，矿机在线状态不再短暂显示为离线。
- Docker 部署优化为 `docker compose up -d --build` 一键构建启动（发布包自带 Dockerfile，不再依赖镜像仓库拉取）。
- 产品名称统一为“用户服务器”。

## Ubuntu 直接部署

1. 将 `ubuntu/` 整个目录上传到服务器。
2. `sudo bash ubuntu/install.sh`
3. 访问 `http://<服务器IP>:18808` 完成首次初始化。

## Docker 部署

1. 将 `docker/` 整个目录上传到服务器。
2. `cd docker && cp .env.example .env`，按需修改环境变量。
3. 启动：

``bash
docker compose up -d --build
``

4. 数据保存在 `docker/data/`。

## 端口

- `18808` 网页控制台
- `19809` 矿机通信通道
- `21080-21089` VPN 等扩展端口

## 校验

``
sha256sum -c SHA256SUMS.txt
``

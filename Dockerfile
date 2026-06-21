FROM ghcr.io/foundry-rs/foundry:latest

WORKDIR /app

# 创建 forge 需要的输出目录并授权
USER root
RUN mkdir -p out cache && chown -R foundry:foundry /app
USER foundry

# 先复制依赖清单，利用 Docker 层缓存
COPY foundry.toml foundry.lock ./
COPY lib ./lib

# 复制合约源码和测试
COPY src ./src
COPY test ./test

ENTRYPOINT ["forge"]
CMD ["test", "-vvv"]

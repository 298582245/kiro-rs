FROM oven/bun:1-alpine AS frontend-builder

WORKDIR /app/admin-ui
COPY admin-ui/package.json admin-ui/bun.lock* ./
RUN bun install --frozen-lockfile --ignore-scripts
COPY admin-ui ./
RUN bun run build

# ---- Rust 构建基座：装好工具链 + cargo-chef ----
# 这一层只随基础镜像 / cargo-chef 版本变化，日常改代码时长期命中缓存。
FROM rust:1.92-alpine AS chef
RUN apk add --no-cache musl-dev perl make
RUN cargo install cargo-chef --locked
WORKDIR /app

# ---- planner：把依赖清单蒸馏成 recipe.json ----
# recipe.json 只反映 Cargo.toml / Cargo.lock 的依赖，不含业务代码内容，
# 因此「只改 src、不动依赖」时 recipe 不变 → 下面的 cook 层整层命中缓存。
FROM chef AS planner
COPY Cargo.toml Cargo.lock* ./
COPY src ./src
RUN cargo chef prepare --recipe-path recipe.json

# ---- builder：先只编依赖（可缓存），再编本项目代码 ----
FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
# 关键：cook 的编译参数必须与最终 build 完全一致（--release --no-default-features），
# 否则依赖以不同 feature/profile 编出，最终 build 时会全部重编，缓存等于白设。
RUN cargo chef cook --release --no-default-features --recipe-path recipe.json
# 到这里几十个依赖已编好并缓存；下面只有本项目代码随 src 变化重编（数十秒）。
COPY Cargo.toml Cargo.lock* ./
COPY src ./src
# admin-ui/dist 仅最终编译本项目时需要（RustEmbed 编译期读取），cook 阶段用不到，
# 故放在这里 COPY，避免前端产物变化打断依赖缓存。
COPY --from=frontend-builder /app/admin-ui/dist /app/admin-ui/dist
RUN cargo build --release --no-default-features

FROM alpine:3.21

RUN apk add --no-cache ca-certificates

WORKDIR /app
COPY --from=builder /app/target/release/kiro-rs /app/kiro-rs

VOLUME ["/app/config"]

EXPOSE 8990

CMD ["./kiro-rs", "-c", "/app/config/config.json", "--credentials", "/app/config/credentials.json"]

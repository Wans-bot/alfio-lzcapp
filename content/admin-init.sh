#!/bin/sh
# alf.io 首次启动时会用一个随机管理员密码建 admin 账号（只打印在容器日志里，
# 上游 ConfigurationStatusChecker.java:68 写死 generateRandomPassword()，没有任何
# 环境变量可以指定）。普通用户装完拿不到日志 => 根本登录不进去，不符合「开箱即用」。
#
# 这个一次性初始化脚本等到 admin 账号出现后，把它改成部署参数里的密码，并在 configuration
# 表里写一个标记，保证只改一次；用户之后在管理后台自己改的密码不会被重新覆盖。
set -e

PG="psql -h postgres -U alfio -d alfio -v ON_ERROR_STOP=1"

# 等 alf.io 建好 admin 账号（它自己会跑 flyway 迁移）。
# 注意：`psql -tAc` 查到 0 行时退出码仍是 0，所以必须比对输出内容；
# 若写成 `until $PG -tAc ...`，flyway 刚建表就会跳出循环，UPDATE 影响 0 行。
until [ "$($PG -tAc "select 1 from ba_user where username='admin'" 2>/dev/null | tr -d '[:space:]')" = "1" ]; do
  sleep 3
done

# bcrypt($2a$) 由 pgcrypto 提供，和 alf.io 用的 BCryptPasswordEncoder 兼容
$PG -q -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

# BASE_URL 是 alf.io 的**必填**系统配置。不填时后台核心接口直接 500：
#   java.lang.IllegalArgumentException: Mandatory configuration key BASE_URL not present
#   at alfio.controller.api.admin.ConfigurationApiController ...
#   -> GET /admin/api/configuration/instance-settings 返回 500
# alf.io 自己没有从 Host 头推断，只能在这里按平台给的域名写一条。
# 只在缺失时写，用户在后台改过就不覆盖。
if [ -n "$LAZYCAT_APP_DOMAIN" ]; then
  $PG -q -c "INSERT INTO configuration (c_key, c_value, description)
             VALUES ('BASE_URL', 'https://$LAZYCAT_APP_DOMAIN', 'Base application url')
             ON CONFLICT (c_key) DO NOTHING;"
  echo "lazycat: BASE_URL=https://$LAZYCAT_APP_DOMAIN"
fi

# 幂等：先看密码是不是已经是我们要的值；不是且从未初始化过，才改一次。
# 标记只在密码确实改成功之后才写，避免「标记写了但密码没改」的死状态。
# 用户名/密码来自部署参数（与 inject 用的是同一组），安装时随机生成，不再是弱口令。
ADMIN_USER="${LZC_ADMIN_USER:-admin}"
ADMIN_PASS="${LZC_ADMIN_PASSWORD:-}"
if [ -z "$ADMIN_PASS" ]; then
  echo "lazycat: 缺少 LZC_ADMIN_PASSWORD（部署参数未注入），不改密码" >&2
  while true; do sleep 3600; done
fi

while true; do
  OK=$($PG -tAc "select count(*) from ba_user where username='${ADMIN_USER}' and password = crypt('${ADMIN_PASS}', password)")
  if [ "$OK" = "1" ]; then
    echo "lazycat: admin password ok (${ADMIN_USER} / 与部署参数一致)"
    break
  fi
  MARK=$($PG -tAc "select count(*) from configuration where c_key='LAZYCAT_ADMIN_SEEDED'")
  if [ "$MARK" != "0" ]; then
    echo "lazycat: 已初始化过（用户可能自己改过密码），跳过"
    break
  fi
  $PG -q -c "UPDATE ba_user SET password = crypt('${ADMIN_PASS}', gen_salt('bf', 10)) WHERE username = '${ADMIN_USER}';"
  $PG -q -c "INSERT INTO configuration (c_key, c_value, description) VALUES ('LAZYCAT_ADMIN_SEEDED', 'true', 'lazycat: admin password seeded') ON CONFLICT (c_key) DO NOTHING;"
  sleep 2
done

# depends_on 只保证这个容器能起来；保持常驻，避免反复重启
while true; do sleep 3600; done

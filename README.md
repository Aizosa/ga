# 在 GitHub Actions 上编译带 NLS 的 GNU GCC 16.2.0

目标：在 **x86_64** 的 macOS 26 runner 上原生 bootstrap 一个
`--enable-nls` 的 GNU GCC 16.2.0，打包成可部署到本机 Intel macOS 虚拟机
（guest：`x86_64-apple-darwin25.6.0` / macOS 26.7.3）的产物。

> 为什么不用本地 VM 编译：guest 只有 6G 内存，bootstrap 全语言峰值高、
> 曾触发宿主 OOM。GitHub 的 macOS Intel runner 有 14G 内存，编译不占本机资源。

## 目录结构

```
gcc-actions/
├── .github/workflows/build-gcc.yml   # Actions 工作流（手动触发）
├── scripts/build-gcc.sh              # 下载 / 前置库 / configure / bootstrap / 打包
└── README.md
```

## 关键决策

| 项 | 值 |
|---|---|
| Runner | `macos-26-intel`（**x64**；`macos-26` 是 arm64，架构不匹配，不能用） |
| GCC 版本 | 16.2.0 |
| 语言 | `c,c++,fortran,objc,obj-c++,jit`（首轮裁剪集合；ada/go 暂缓，见第五节） |
| NLS | `--enable-nls --with-libintl-prefix=<gettext>` |
| 前置库 | gmp 6.3.0 / mpfr 4.2.2 / mpc 1.3.1 / isl 0.24，**源码内嵌**编译，静态进 GCC，不依赖 Homebrew dylib |
| libintl | 来自 runner 的 Homebrew gettext；运行时依赖 guest 已装的 MacPorts gettext |
| 安装前缀（产物内） | 解压后对应 `~/opt/gcc-16.2.0` |
| 程序后缀 | `-16`（`gcc-16` / `g++-16` …） |

## 一、建仓并推送（你有 GitHub 账号，仓库需新建）

1. 在 GitHub 网页上新建一个**空仓库**（不要勾 README / .gitignore），
   例如 `<你的用户名>/gcc-actions`。
2. 本地执行：

```bash
cd ~/项目/gcc-actions
git init -b main
git add .
git commit -m "Build GCC 16.2.0 with NLS on macOS 26 Intel runner"

# 用 SSH（已把公钥加到 GitHub）：
git remote add origin git@github.com:<你的用户名>/gcc-actions.git
# 或用 HTTPS：
# git remote add origin https://github.com/<你的用户名>/gcc-actions.git

git push -u origin main
```

## 二、触发构建

1. 打开仓库 → **Actions** 标签。
2. 左侧选 **Build GCC 16.2.0 (x86_64, NLS)**。
3. **Run workflow** → 选 `main` → 运行。
4. 工作流为手动触发，不会在 push 时自动跑。

> 标准 Intel runner 只有 3 核，bootstrap 可能接近 job 的 6 小时上限；
> 工作流已设 `timeout-minutes: 330`。若超时，先核对日志阶段再重跑。

## 三、取回产物

构建成功后，在运行页面底部 **Artifacts** 下载：

- `gcc-16.2.0-x86_64-darwin26-nls`：GCC 安装树的 tar.gz。
- `gcc-build-reports`：版本、动态库依赖、NLS `.mo` 清单、已装前端列表（失败也会上传）。

解压本地得到 `gcc-16.2.0-x86_64-darwin26-nls.tar.gz`。

## 四、装进 guest 虚拟机

先把 guest VM 启动，确认 SSH 通（转发端口 2222）：

```bash
# 上传产物到 guest
scp -P 2222 gcc-16.2.0-x86_64-darwin26-nls.tar.gz arch@127.0.0.1:~/

# 解压到用户前缀
ssh -p 2222 arch@127.0.0.1 'mkdir -p ~/opt/gcc-16.2.0 && \
  tar -C ~/opt/gcc-16.2.0 -xzf ~/gcc-16.2.0-x86_64-darwin26-nls.tar.gz'
```

加入 PATH（`~/.zshrc`）：

```bash
export PATH="$HOME/opt/gcc-16.2.0/bin:$PATH"
export LDFLAGS="-L$HOME/opt/gcc-16.2.0/lib"
export CPPFLAGS="-I$HOME/opt/gcc-16.2.0/include"
```

验证：

```bash
gcc-16 --version
g++-16 --version
otool -L "$(command -v gcc-16)" | grep -i intl
find ~/opt/gcc-16.2.0 -name '*.mo' | head
```

### libintl 路径坑（重要）

runner 上 gettext 装在 Homebrew 前缀（Intel 为 `/usr/local/opt/gettext/...`），
产物里记录的可能是这条 **runner 专属路径**；guest 上 gettext 在
`/opt/local/lib/libintl.8.dylib`。装机后若 `otool -L` 看到指向
`/usr/local/opt/gettext/...` 的依赖，二选一处理：

```bash
# 临时：运行时把 guest gettext 库目录加入搜索路径
export DYLD_LIBRARY_PATH=/opt/local/lib

# 永久：把二进制里的旧路径改到 guest 实际路径
install_name_tool -change \
  /usr/local/opt/gettext/lib/libintl.8.dylib \
  /opt/local/lib/libintl.8.dylib \
  ~/opt/gcc-16.2.0/bin/gcc-16 ~/opt/gcc-16.2.0/bin/g++-16
```

前置 gmp/mpfr/mpc/isl 已内嵌静态链接，不存在这条路径问题。

## 五、语言集合

首轮采用 Darwin 上可稳定构建的裁剪集合：

```sh
LANGUAGES="c,c++,fortran,objc,obj-c++,jit"
```

以下前端暂缓，未纳入首轮：

- **Ada**：GCC 自举需要宿主已存在 GNAT 引导编译器，runner 上没有，configure/bootstrap 会失败。
- **Go (gccgo)**：前端长期失修，Darwin 上很可能编不过。
- `algol68` 为 16 新增前端，成熟度未知；源码树内没有 brig 前端。

链路跑通、产物能装进 guest 验证可用后，若要补前端，把
`scripts/build-gcc.sh` 里的 `LANGUAGES` 改成目标集合（或 `all`），
提交后重新触发工作流。

## 六、已知限制

- 产物面向 `x86_64-apple-darwin26`，与本机 Intel guest 同大版本；不要装到 arm64 Mac。
- CI 不交叉编译：runner 是真 macOS，GCC 在其中原生自举，产物可直接在 guest 运行。
- 仓库为 public：标准 GitHub-hosted runner 的 job 分钟数免费；artifact 存储单独计量（本任务产物仅一个 tar.gz，量很小）。
- 若 Homebrew 在该 runner 上缺某个 bottle，会退回本地编译，进一步拉长构建时间。

# docs-build

用 GitHub Actions 手动触发构建 **离线文档站点**。覆盖 8 个上游项目：
vllm-ascend、recipes（vllm-project）、ruff / uv / ty（astral-sh）、Pi 中文文档、
litellm-docs（BerriAI）、vllm-omni（vllm-project）。
本仓库只存放「构建编排 + 离线化补丁」，不改动上游。

## 它是怎么工作的

```
GitHub Actions（手动触发）
  ├─ checkout 上游仓库到指定 ref（分支 / tag / commit）
  ├─ git apply patches/<项目>/offline.patch   ← 你的离线化改动
  ├─ 按项目构建（mkdocs / next export）
  └─ 打包 zip → Artifacts（可选：发布到 Release）
```

用补丁而不是 fork，是为了让「上游代码」和「你的个性化改动」保持分离：
上游更新后重新打补丁即可，冲突点也一目了然。

## 每个流程的预估时间

checkout 上游 + 打补丁都在 1 分钟内（vllm-ascend 全量克隆约 120 MB，其余更快），
时间基本全花在构建上。下表「实测」是这台 Windows 机器（8 核、node_modules 与
Python venv 已就绪、外网可用）跑出来的；「CI 预估」是 GitHub 托管 runner 上的
经验值，比本机快一些，但每个 job 都要重新装依赖，首次会更慢。两者都**不含**首次
装工具链（pip / npm / Rust / uv）。

| 流程 | 实测 | CI 预估 | 时间花在哪 |
| --- | --- | --- | --- |
| vllm-ascend（单语） | ~20 秒 | 3–5 分钟 | 构建本身极快，CI 主要在装 pip 依赖 |
| vllm-ascend（`both`） | ~40 秒 | 5–8 分钟 | 中英各跑一遍 |
| recipes MkDocs | ~1 分钟 | 3–5 分钟 | privacy 插件逐张抓正文外链图片 |
| recipes Next | ~22 分钟 | 10–15 分钟 | 生成 1.9 万个 API JSON 占 90%（约 20 分钟），`next build` 只要 2 分钟 |
| ruff | 5–10 分钟（估） | 8–12 分钟 | `cargo dev` 现场编 Rust 导出规则页 |
| uv | 10–20 分钟（估） | 12–20 分钟 | 同上，还要生成 CLI / 环境变量参考页 |
| ty | 1–2 分钟（估） | 3–5 分钟 | 参考页已入库，不需要 Rust |
| Pi | ~1 分钟 | 3–4 分钟 | `pnpm install` 占大头 |
| LiteLLM | ~31 分钟 | 20–30 分钟 | 3358 张图过一遍 optimize-images |
| vLLM-Omni | ~56 分钟 | 50–70 分钟 | 1855 页，每页重新解析整个包 |
| **build-all（全并行）** | ≈ 最慢的那个（vllm-omni） | ≈ 60–70 分钟 | 各 job 并行，总时长被 omni 拖住 |

工作流的 `timeout-minutes` 都按上表留了余量：recipes 的 Next job 120 分钟、
vllm-omni 150 分钟，其余 60–120 分钟。实测某个站点明显超过 1.5 倍预估时间时，
先看是不是在「Collecting build traces」或者外链抓取上卡住，而不是直接加超时。

## 目录

| 路径 | 说明 |
| --- | --- |
| `.github/workflows/build-vllm-ascend.yml` | vLLM Ascend 站点（中/英） |
| `.github/workflows/build-recipes.yml` | vLLM Recipes 的两套站点（MkDocs + Next.js） |
| `.github/workflows/build-astral.yml` | ruff / uv / ty 三个 MkDocs 站点（矩阵并行） |
| `.github/workflows/build-pi.yml` | Pi 中文文档（rspress，无需补丁） |
| `.github/workflows/build-litellm.yml` | LiteLLM 文档（Docusaurus 3.8） |
| `.github/workflows/build-vllm-omni.yml` | vLLM-Omni 文档（MkDocs + mkdocstrings） |
| `.github/workflows/build-all.yml` | 一键构建以上全部 |
| `patches/*/offline.patch` | 各项目的离线化补丁（详见下表） |
| `scripts/apply-patches.sh` | 在 CI 中按序打补丁 |
| `scripts/make-patches.sh` | 从本地仓库重新导出补丁 |
| `scripts/build-*.sh` | 真正的构建命令，CI 与本地共用 |

补丁内容：

| 补丁 | 改了什么 |
| --- | --- |
| `patches/vllm-ascend` | `offline`/`privacy` 插件、去 CDN 字体、site_url/repo_url 换内网地址 |
| `patches/recipes` | MkDocs 站：关闭 `strict`、去掉 Material 的 GitHub star 请求、移除无人使用的 MathJax；Next 站：`output: 'export'`、logo 从 docs.vllm.ai 下载到 `public/logos`、去掉首页 `meta refresh` 跳转、**侧边栏 props 裁到 5 个字段（产物 1.5 GB → 343 MB）** |
| `patches/ruff` | 在 `mkdocs.template.yml` 里加 `font: false` + `privacy`/`offline`，去 fathom 统计，去 docs.astral.sh 图标外链，`source.html` 去掉 `api.github.com` 请求 |
| `patches/uv` | 同 ruff（配置在 `mkdocs.yml`） |
| `patches/ty` | 同 ruff（配置在 `mkdocs.yml`） |
| `patches/litellm-docs` | 去掉 PostHog / GA4 / FeedbackRocket 三个运行时脚本与 Google Fonts `@import` |
| `patches/vllm-omni` | `font: false` + `privacy`/`offline`，Slack 图标改内联 SVG，MathJax / Mermaid 改本地副本，`site_url` 支持环境变量覆盖 |

### 为什么会有 `overrides/partials/source.html`

mkdocs-material 的仓库按钮带 `data-md-component="source"` 时，`bundle.js` 会去
`https://api.github.com/repos/<org>/<repo>` 和 `.../releases/latest` 取 star 数和最新版本。
断网环境下这些 XHR 要等 DNS 超时，内网部署时表现为「打开页面后转圈一会儿」。
补丁里的覆盖模板保留同样的 DOM 和图标，只去掉那个属性，按钮退化成普通链接，不再发请求。

## 首次使用

1. 把这个仓库推到 GitHub（私有仓库也可以）。
2. 仓库 **Settings → Actions → General → Workflow permissions**：
   勾选 *Read and write permissions*（发布 Release 需要；只用 Artifacts 可保持只读）。
3. **Actions** 页面 → 左侧选一个工作流 → **Run workflow** 按钮。

命令行触发也可以：

```bash
gh workflow run "离线文档 · vLLM Ascend" -f lang=zh -f ref=main
gh workflow run "离线文档 · vLLM Recipes" -f site=all -f ref=main
gh workflow run "离线文档 · Astral (ruff / uv / ty)" -f project=all -f ref=main
# 只把 uv 固定在某个 tag，ruff/ty 仍跟 main：
gh workflow run "离线文档 · Astral (ruff / uv / ty)" -f project=all -f uv_ref=0.9.0
gh workflow run "离线文档 · Pi 中文文档" -f ref=master
gh run watch
```

## 输入参数

**vLLM Ascend**

| 参数 | 说明 |
| --- | --- |
| `lang` | `zh` / `en` / `both`，中英文各自独立构建、独立打包 |
| `ref` | 上游分支、tag 或 commit，默认 `main` |
| `site_url` | 站点根地址；留空则沿用补丁里写死的内网地址 `<http://vllm-ascend/docx.cw.com/>` |
| `publish_release` | 勾选后把 zip 发到 Releases |

**vLLM Recipes**

| 参数 | 说明 |
| --- | --- |
| `site` | `mkdocs`（Markdown 指南）/ `next`（Next.js 站点）/ `all` |
| `ref` | 上游 ref，默认 `main` |
| `site_url` | 同时作用于 mkdocs 的 `READTHEDOCS_CANONICAL_URL` 和 Next 的 `NEXT_PUBLIC_SITE_URL` |
| `publish_release` | 同上 |

**Astral（ruff / uv / ty）**

| 参数 | 说明 |
| --- | --- |
| `project` | `ruff` / `uv` / `ty` / `all`，每个项目一个并行 job |
| `ref` | 三个仓库的**默认** ref，默认 `main`；下面三项留空时都用它 |
| `ruff_ref` | ruff 专用 ref，可填 tag / commit（如 `0.14.0`）；留空 = 用 `ref` |
| `uv_ref` | uv 专用 ref（如 `0.9.0` 而非 `main`）；留空 = 用 `ref` |
| `ty_ref` | ty 专用 ref；留空 = 用 `ref` |
| `publish_release` | 同上 |

> 三个仓库发版节奏不一样，想固定某个仓库的版本只填它自己的那一项即可，
> 例如 `project=all` + `uv_ref=0.9.0` 会构建 `ruff@main` / `uv@0.9.0` / `ty@main`。
> plan job 先在日志里打印解析出的矩阵（`构建矩阵: [...]`），矩阵里的 ref 就是
> 每个 job 实际 checkout 的 ref，也直接写进 job 名和构建摘要。
>
> 注意：补丁是针对**当前上游**写的，钉到一个很旧的 tag（比如 ruff 0.9.x）时
> `git apply --3way` 很可能冲突、构建失败。要长期固定旧版本，得另外导出一份
> 对应版本的补丁（`make-patches.sh` 是在本地 checkout 上导出的）。

**Pi 中文文档**

| 参数 | 说明 |
| --- | --- |
| `ref` | 默认 `master` |
| `publish_release` | 同上 |

**LiteLLM**

| 参数 | 说明 |
| --- | --- |
| `ref` | 默认 `main` |
| `publish_release` | 同上 |

**vLLM-Omni**

| 参数 | 说明 |
| --- | --- |
| `ref` | 默认 `main` |
| `site_url` | 写入 canonical / sitemap，通过 `OFFLINE_SITE_URL` 传给 mkdocs |
| `publish_release` | 同上 |

## 产物

| Artifact | 内容 | 体积参考 |
| --- | --- | --- |
| `vllm-ascend-docs-zh` / `-en` | MkDocs 站点 zip | ~15–30 MB |
| `recipes-mkdocs-offline` | MkDocs 站点 zip | 几十 MB |
| `recipes-next-offline` | Next.js 静态站点 zip | **~56 MB（解压 343 MB / 20760 文件）** |
| `ruff-offline` / `uv-offline` / `ty-offline` | MkDocs 站点 zip | ~10–25 MB |
| `pi-docs-offline` | rspress 静态站点 zip | ~20 MB |
| `litellm-docs-offline` | Docusaurus 静态站点 zip | ~700 MB（解压 ~730 MB） |
| `vllm-omni-offline` | MkDocs 站点 zip | ~200 MB（解压 207 MB，1855 页） |

### recipes-next 为什么曾经有 1.5 GB，现在只有 343 MB

2026-10-23 实测的构成（优化前 → 优化后）：

| 部分 | 优化前 | 优化后 | 说明 |
| --- | --- | --- | --- |
| 447 个页面的 `html` | 726 MB | 109 MB | 每页内联一份 RSC payload |
| 449 个 `txt`（RSC payload） | 658 MB | 85 MB | 客户端跳转时用 |
| 19769 个 API `json` | 101 MB | 101 MB | 真实内容，`build-recipes-api.mjs` 生成 |
| `_next` 静态资源 | 1.5 MB | 1.5 MB | 正常 |
| `/providers` 厂商图标 | 269 KB | 269 KB | 一共 43 个文件，**不是**体积瓶颈 |

真正的冗余在侧边栏：`src/app/[org]/layout.js` 把 `getAllRecipes()` 的**完整对象**
（每条带 `meta` / `variants` / `features` / `omni` / `model` / `hardware_overrides`，
约 2.8 KB）作为 props 传给客户端组件 `ModelSidebar`。客户端组件的 props 会被静态
导出序列化进**每一个页面**——192 条 ≈ 540 KB，而这份数据在 `html` 内联脚本和同名
`.txt` 里各存一份，447 个页面就是 1 GB 级的纯重复。

`patches/recipes` 里把这个 props 裁成侧边栏真正用到的 5 个字段
（`hf_id` / `hf_org` / `hf_repo` / `meta.title` / `meta.provider` / `meta.tasks`），
体积降到约 25 KB/页：产物 1.48 GB → 343 MB，zip 306 MB → 56 MB，页面大小
1.86 MB → 360 KB，而侧边栏的展开/高亮/搜索行为完全不变（实测 `Qwen/…` 页仍渲染
33 个同 org 模型链接，外链 0）。

要继续瘦身，下一个目标是每页那份 `txt`（只服务客户端跳转）：如果接受「站内跳转
走整页刷新」，可以把 `*.txt` 全删掉，还能再省 ~85 MB。


下载解压后：

- **MkDocs 站点**（vllm-ascend / recipes-mkdocs / ruff / uv / ty）：`offline` 插件已把字体、
  图标内联进站点，直接双击 `index.html` 就能离线浏览，也可以整个目录拷到内网 Web 根目录。
- **根路径静态站点**（recipes-next / pi-docs / litellm-docs）：页面里是 `/_next/...`、`/assets/...`
  这类根路径资源，**不能**用 `file://` 打开，需要一个静态服务器。本地验证：
  `cd 解压目录 && python -m http.server 8000`；内网部署时放到站点根目录（不要再套一层子路径）。

都不需要在目标机器上装 Node/Python 运行时。

Artifacts 默认保留 30 天；要长期留存就勾 `publish_release`，或把 retention 改大。

## 更新个性化改动

日常流程：先在本地仓库里改到满意，再导出补丁。

```bash
# 1. 在本地仓库改动（D:\tmp\aaaupdate\docs 下的 vllm-ascend / recipes / ruff / uv / ty）
# 2. 看看改了什么
git -C /d/tmp/aaaupdate/docs/vllm-ascend diff
git -C /d/tmp/aaaupdate/docs/ruff diff

# 3. 重新导出补丁（默认读 /d/tmp/aaaupdate/docs）
bash scripts/make-patches.sh
# 或指定根目录
DOCS_SRC=/d/somewhere bash scripts/make-patches.sh

# 4. 提交
git add patches && git commit -m "update offline patches"
```

`make-patches.sh` 导出**已跟踪文件**的改动，另外自动把新增的模板与静态资源
（`overrides/`、`.overrides/`、`public/logos/` 下的新文件）以 intent-to-add 方式纳入补丁，
所以 `source.html`、logo 这类新文件不用手动 `git add`。其余未跟踪文件（构建产物 zip、lock 等）会被忽略。

上游改动导致补丁打不上时，工作流会在「应用离线化补丁」这步直接失败，
并在日志里给出 `::error` 提示 —— 此时回到本地 `git pull` 解决冲突后重新导出补丁。

## 本地复现（不依赖 Actions）

```bash
SRC=/d/tmp/aaaupdate/docs
OUT=/tmp/docs-out

# vLLM Ascend 中文
git clone --depth 1 https://github.com/vllm-project/vllm-ascend.git /tmp/ascend
bash scripts/apply-patches.sh /tmp/ascend patches/vllm-ascend
python -m venv /tmp/venv && /tmp/venv/Scripts/pip install -r /tmp/ascend/docs/requirements-docs.txt
bash scripts/build-vllm-ascend.sh /tmp/ascend "$OUT/ascend-zh" zh

# ty（不需要 Rust，最快验证链路）
git clone https://github.com/astral-sh/ty.git /tmp/ty
bash scripts/apply-patches.sh /tmp/ty patches/ty
bash scripts/build-astral.sh ty /tmp/ty "$OUT/ty"

# Pi 文档
git clone https://github.com/Q-Peppa/Q-Peppa.github.io.git /tmp/pi
(cd /tmp/pi && pnpm install --frozen-lockfile)
bash scripts/build-pi.sh /tmp/pi "$OUT/pi"
```

Recipes 的两套站点同理，见 `scripts/build-recipes-*.sh` 顶部注释。

## 验证产物是否真的离线

两个脚本，一个静态扫、一个真浏览器跑：

```bash
# 1) 静态扫描：HTML/CSS 里还有哪些会发请求的外链
python scripts/audit-offline.py out/litellm-docs
# 退出码 0 = 没有 BLOCKING 外链

# 2) 真浏览器：起本地服务 + 无头 Edge，拦掉所有非 127.0.0.1 请求，量首屏时间
npm i puppeteer-core          # 只装驱动，不下载浏览器
node scripts/check-site-offline.mjs out/litellm-docs --sample 6
```

`check-site-offline.mjs` 会用本机已装的 Edge/Chrome（`CHROME_PATH` 可指定），
输出每页 FCP / DOMContentLoaded / load 与被拦截的外链条数——被拦截仍能正常渲染，
说明断网打开不会卡。

## 已知注意点

- **recipes 的 Next 构建依赖网络**：`pnpm build` 会执行 `build-recipes-api.mjs`
  （纯本地，但要在 Windows 上生成 1.9 万个 JSON，约 20 分钟）、`fetch-provider-logos.mjs`
  （抓 huggingface 头像）、`fetch-hf-dates.mjs`（抓发布日期），最后 `next build`
  里的 `next/font/google` 还要从 Google Fonts 下字体。GitHub 托管 runner 上前两个
  没问题，但断网时会分别报 `NextFontError: Failed to fetch ...` 或让 logo 抓取变慢。
  前两个脚本都**跳过已存在的文件**，所以第二次构建会快很多。
- **recipes 的 MkDocs 不再用 `--strict`**：补丁把 `mkdocs.yml` 的 `strict: true` 改成了
  `false`。privacy 插件抓外链时，上游任一外链 404（ajv）或超时（vimeo）都会变成
  warning，strict 会让整站构建中止。要复现严格行为手动跑 `mkdocs build --strict`。
- **`git-revision-date-localized`** 需要完整 git 历史，所以 recipes 的 MkDocs 任务
  用了 `fetch-depth: 0`；vllm-ascend 为了 `git apply --3way` 能拿到基础 blob 也用了 0。
- 仓库体积：vllm-ascend 全量 clone 约 120 MB，recipes 更大；各任务是独立 job，互不影响。
- **Astral 的 ruff / uv 需要 Rust**：`cargo dev generate-docs`（ruff）和
  `cargo dev generate-*-reference`（uv）要现场编译，首次 10–20 分钟，
  有 `Swatinem/rust-cache` 后重复构建会快很多。ty 的参考页已入库，不需要 Rust。
- **本机 uv 版本要够新**：ty / uv 的 `pyproject.toml` 用了
  `[tool.uv] require-build-hashes` 和带 `hashes` 的 build-constraint 写法，
  uv 0.12.15 会直接报 `unknown field require-build-hashes` 然后退出。
  CI 用 `astral-sh/setup-uv@v10.3.3` 装最新版没问题；本机先 `uv self update`。
- **`setup-uv` 必须写完整版本号**：它**不发布滚动大版本 tag**（`v10` / `v9` / `v8` 都不存在，
  只有 `v10.3.3` 这类完整号）。写成 `@v10` 会在「解析 action」阶段就失败，报
  `Unable to resolve action astral-sh/setup-uv@v10, unable to find version v10`，
  job 连第一步都跑不到。升级时去 releases 页改完整版本号。
- **`privacy` 插件在构建期仍要联网**：它把 markdown 里的外链图片下载到 `assets/external/`，
  产物本身不再请求外网。构建机上没网就会失败。**注意它下载时没有超时**：vllm-omni 的
  `mkdocs.yml` 因此没用 `privacy`，改由 `scripts/localize-external-assets.py` 在构建后处理
  （并发、有超时、失败只降级），否则一个不可达的图片域名就能把构建挂死。
- **LiteLLM 站点体积大、构建慢**：上游 2245 个页面、3358 张图要过一遍 optimize-images，
  本地 31 分钟、产物体积 672 MB（其中 `assets/` 408 MB）。GitHub 托管 runner 会快一些，
  但 Artifacts 下载也要等。要减小体积只能在 `patches/litellm-docs` 里删掉 social-cards 之类的产物。
- **LiteLLM 正文里的图片走 CDN**：博主头像（`pbs.twimg.com`、`media.licdn.com`）、录屏截图
  （`colony-recorder.s3.amazonaws.com`）都在 markdown 里写死。构建后由本地化脚本抓下来，
  少数域名（LinkedIn、S3 私有桶）会 403 拒绝非浏览器请求，这些保留原 URL——断网时只是缺图。
- **vllm-omni 构建非常慢**：`api-autonav` + `mkdocstrings` 会生成约 1800 个虚拟 API 页，
  而 mkdocstrings 每渲染一页都会重新 `griffe: Loading path ...` 把整个 `vllm_omni` 包
  再解析一遍。本地（Windows、单核渲染）实测 1.5 小时以上，GitHub runner 也在同一量级，
  所以工作流 `timeout-minutes` 给到 150。想快只能砍 `mkdocs.yml` 里 `api-autonav` 的
  `modules` 范围。
- **vllm-omni 的构建钩子会改写文档源文件**：`generate_examples.py` / `generate_api_readme.py` /
  `awesome-nav` 会就地重写 `docs/user_guide/examples/`、`docs/api/`、`docs/.nav.yml`。
  这些是构建副产物，`make-patches.sh` 已排除，别手动 `git add` 进去。
- **Windows 本地构建的两个坑**（CI 上没有）：
  1. 宿主通过 `NODE_OPTIONS` 注入的 `--require` 垫片会拦下 `next` 构建脚本里的 `rmSync`，
     各构建脚本已在开头 `unset NODE_OPTIONS`。
  2. `next build` 偶尔在 `EPERM: open '.next/trace'` / `EPERM: open 'out/404.html'`
     上直接失败。脚本已经 `rm -rf .next` 并预建空的 `.next/trace`；`out/404.html` 还是
     报错的话，把 `out/` 改名挪走（`mv out out_old`）再重跑，别用 `rm -rf out` 逐个删。
- **外链本地化写的是相对路径**：`localize-external-assets.py` 会把
  `https://…/a.png` 改写成 `../../assets/external/<sha1>.png`，这样 MkDocs 站点在
  `file://` 下直接打开也不会断图（根路径 `/assets/...` 在 `file://` 下会指向磁盘根）。
- **Pi 文档仍带 Google Analytics**：`rspress.config.ts` 里的 `pluginGoogleAnalytics`
  会在页面里注入 GA 脚本。如果要“零外网请求”，删掉那个 plugin 和 `rsbuild-plugin-google-analytics`
  依赖即可（目前按你的要求保持原样，直接构建）。
- 若不想用 Release，可删掉各工作流里的 `release` job，产物只留 Artifacts。

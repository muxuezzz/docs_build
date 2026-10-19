# docs-build

用 GitHub Actions 手动触发构建 **离线文档站点**。上游是 vllm-project 的两个仓库，
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

## 目录

| 路径 | 说明 |
| --- | --- |
| `.github/workflows/build-vllm-ascend.yml` | vLLM Ascend 站点（中/英） |
| `.github/workflows/build-recipes.yml` | vLLM Recipes 的两套站点（MkDocs + Next.js） |
| `.github/workflows/build-all.yml` | 一键同时构建上面两个 |
| `patches/vllm-ascend/offline.patch` | 离线化补丁（offline/privacy 插件、去 CDN 字体、内网地址） |
| `patches/recipes/offline.patch` | 同上 + `output: 'export'`、去掉 huggingface.co 外链 |
| `scripts/apply-patches.sh` | 在 CI 中按序打补丁 |
| `scripts/make-patches.sh` | 从本地仓库重新导出补丁 |
| `scripts/build-*.sh` | 真正的构建命令，CI 与本地共用 |

## 首次使用

1. 把这个仓库推到 GitHub（私有仓库也可以）。
2. 仓库 **Settings → Actions → General → Workflow permissions**：
   勾选 *Read and write permissions*（发布 Release 需要；只用 Artifacts 可保持只读）。
3. **Actions** 页面 → 左侧选一个工作流 → **Run workflow** 按钮。

命令行触发也可以：

```bash
gh workflow run "离线文档 · vLLM Ascend" -f lang=zh -f ref=main
gh workflow run "离线文档 · vLLM Recipes" -f site=all -f ref=main
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

## 产物

| Artifact | 内容 | 体积参考 |
| --- | --- | --- |
| `vllm-ascend-docs-zh` / `-en` | MkDocs 站点 zip | ~15–30 MB |
| `recipes-mkdocs-offline` | MkDocs 站点 zip | 几十 MB |
| `recipes-next-offline` | Next.js 静态站点 zip | ~300 MB（解压 ~1.5 GB） |

下载解压后：

- **MkDocs 站点**（vllm-ascend / recipes-mkdocs）：`offline` 插件已把字体、图标内联进站点，
  直接双击 `index.html` 就能离线浏览，也可以整个目录拷到内网 Web 根目录。
- **Next.js 站点**（recipes-next）：页面里是 `/_next/...` 这类根路径资源，**不能**用
  `file://` 打开，需要一个静态服务器。本地验证：`cd 解压目录 && python -m http.server 8000`；
  内网部署时放到站点根目录（不要再套一层子路径）。

两者都不需要在目标机器上装 Node/Python 运行时。

Artifacts 默认保留 30 天；要长期留存就勾 `publish_release`，或把 retention 改大。

## 更新个性化改动

日常流程：先在本地仓库里改到满意，再导出补丁。

```bash
# 1. 在本地仓库改动（D:\tmp\aaaupdate\docs\vllm-ascend 或 recipes）
# 2. 看看改了什么
git -C /d/tmp/aaaupdate/docs/vllm-ascend diff
git -C /d/tmp/aaaupdate/docs/recipes diff

# 3. 重新导出补丁（默认读 /d/tmp/aaaupdate/docs）
bash scripts/make-patches.sh
# 或指定根目录
DOCS_SRC=/d/somewhere bash scripts/make-patches.sh

# 4. 提交
git add patches && git commit -m "update offline patches"
```

`make-patches.sh` 只导出**已跟踪文件**的改动（`git diff`）。新加的文件要先 `git add`
（或至少 `git add -N`），否则不会进补丁。

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
```

Recipes 的两套站点同理，见 `scripts/build-recipes-*.sh` 顶部注释。

## 已知注意点

- **recipes 的 Next 构建依赖网络**：`pnpm build` 会执行 `fetch-provider-logos.mjs`
  和 `fetch-hf-dates.mjs` 去抓 huggingface 的头像与日期。GitHub 托管 runner 上没问题，
  但如果某天 HF 限流，这两个脚本可能让构建变慢或失败。
- **mkdocs 用了 `--strict`**：任何 warning 都会变成失败。想放宽就去掉脚本里的
  `--strict`（两个 `build-recipes-mkdocs.sh` / `tools/rtd_build.sh` 各自持有）。
- **`git-revision-date-localized`** 需要完整 git 历史，所以 recipes 的 MkDocs 任务
  用了 `fetch-depth: 0`；vllm-ascend 为了 `git apply --3way` 能拿到基础 blob 也用了 0。
- 仓库体积：vllm-ascend 全量 clone 约 120 MB，recipes 更大；两个任务并行跑时不会互相干扰。
- 若不想用 Release，可删掉 `release` job，产物只留 Artifacts。

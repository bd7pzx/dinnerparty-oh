/** 同好页：口味近邻 + 公开收藏夹 + 发现设置（设置项与原项目一致） */
import { Theme } from '../common/Theme';
import { Collection, Neighbor, collectionCount, sharedText } from '../model/Types';
import {
  CollectionContainer, CommunityService, ConsentContainer, FeedbackStats, NeighborContainer
} from '../service/Services';
import { EmptyState, LoadingRow, PrimaryButton, SectionCard } from './Widgets';

@Component
export struct CommunityTab {
  @State neighbors: Neighbor[] = [];
  @State collections: Collection[] = [];
  @State loading: boolean = false;
  @State newTitle: string = '';
  @State tip: string = '';
  @State starW: number = 320;
  @State starH: number = 240;

  /** collections = 公开收藏夹；settings = 发现设置 */
  @State section: string = 'collections';

  // ---- 发现设置状态（字段名与 /api/community/consent 对齐） ----
  @State tagText: string = '';
  @State onDiscovery: boolean = true;
  @State onFeedback: boolean = true;
  @State onResearch: boolean = true;
  @State consentVersion: number = 0;
  @State origResearch: boolean = true;
  @State retentionDays: number = 90;
  @State interactionTotal: number = 0;
  @State saving: boolean = false;
  @State settingsMsg: string = '';
  @State settingsLoaded: boolean = false;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  aboutToAppear(): void {
    this.load();
    this.loadSettings();
  }

  private async load(): Promise<void> {
    this.loading = true;
    const n = await CommunityService.neighbors();
    if (n.ok && n.data !== null) {
      const nc: NeighborContainer = n.data;
      const list = nc.neighbors;
      this.neighbors = list === undefined || list === null ? [] : list;
    } else {
      this.neighbors = [];
    }
    const c = await CommunityService.collections();
    if (c.ok && c.data !== null) {
      const cc: CollectionContainer = c.data;
      const list = cc.collections;
      this.collections = list === undefined || list === null ? [] : list;
    } else {
      this.collections = [];
    }
    this.loading = false;
    this.drawStar();
  }

  // ---------- 发现设置 ----------

  private async loadSettings(): Promise<void> {
    const c = await CommunityService.consent();
    if (c.ok && c.data !== null) {
      const ct: ConsentContainer = c.data;
      this.onDiscovery = ct.discovery === true;
      this.onFeedback = ct.feedback === true;
      this.onResearch = ct.research === true;
      this.origResearch = ct.research === true;
      this.consentVersion = ct.version;
      const tags = ct.tags;
      this.tagText = tags === undefined || tags === null ? '' : tags.join('，');
      this.settingsLoaded = true;
    } else {
      this.settingsMsg = c.status === 401 ? '登录后可调整发现设置' : `读取失败：${c.error}`;
    }
    const s = await CommunityService.feedbackStats();
    if (s.ok && s.data !== null) {
      const st: FeedbackStats = s.data;
      this.retentionDays = st.retention_days;
      const counts = st.counts;
      let total = 0;
      if (counts !== undefined && counts !== null) {
        for (const it of counts) {
          total += it.count;
        }
      }
      this.interactionTotal = total;
    }
  }

  /** 逗号分隔，最多 20 个 */
  private parseTags(text: string): string[] {
    const out: string[] = [];
    let cur = '';
    for (let i = 0; i < text.length; i++) {
      const ch = text.charAt(i);
      if (ch === ',' || ch === '，' || ch === '、') {
        const t = cur.trim();
        if (t.length > 0) {
          out.push(t);
        }
        cur = '';
      } else {
        cur += ch;
      }
    }
    const last = cur.trim();
    if (last.length > 0) {
      out.push(last);
    }
    return out.slice(0, 20);
  }

  private async saveSettings(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    this.settingsMsg = '';
    const tags = this.parseTags(this.tagText);
    const researchChanged = this.onResearch !== this.origResearch;
    const r = await CommunityService.putConsent(
      tags, this.onDiscovery, this.onFeedback, this.onResearch, researchChanged, this.consentVersion
    );
    this.saving = false;
    if (r.ok && r.data !== null) {
      this.settingsMsg = '设置已保存';
      this.origResearch = this.onResearch;
      this.consentVersion = r.data.version;
      this.load();
    } else {
      this.settingsMsg = r.error;
    }
  }

  private async clearInteractions(): Promise<void> {
    const r = await CommunityService.clearFeedback();
    if (r.ok) {
      this.settingsMsg = '交互记录已清除';
      this.loadSettings();
    } else {
      this.settingsMsg = `清除失败：${r.error}`;
    }
  }

  // ---------- 星图 ----------

  /** x/y 全由后端下发，这里只做归一化缩放 */
  private drawStar(): void {
    const w = this.starW;
    const h = this.starH;
    const ctx = this.ctx;
    const pal = Theme.palette();
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = pal.surfaceAlt;
    ctx.fillRect(0, 0, w, h);

    const cx = w / 2;
    const cy = h / 2;
    const r = Math.min(w, h) / 2 - 22;

    ctx.strokeStyle = pal.line;
    ctx.lineWidth = 1;
    for (const k of [0.33, 0.66, 1.0]) {
      ctx.beginPath();
      ctx.arc(cx, cy, r * k, 0, Math.PI * 2);
      ctx.stroke();
    }
    ctx.beginPath();
    ctx.moveTo(cx - r, cy);
    ctx.lineTo(cx + r, cy);
    ctx.moveTo(cx, cy - r);
    ctx.lineTo(cx, cy + r);
    ctx.stroke();

    let maxAbs = 0.05;
    for (const nb of this.neighbors) {
      const ax = Math.abs(nb.x);
      const ay = Math.abs(nb.y);
      if (ax > maxAbs) maxAbs = ax;
      if (ay > maxAbs) maxAbs = ay;
    }
    const scale = r / maxAbs;

    ctx.fillStyle = pal.primary;
    ctx.beginPath();
    ctx.arc(cx, cy, 6, 0, Math.PI * 2);
    ctx.fill();

    for (const nb of this.neighbors) {
      const px = cx + nb.x * scale;
      const py = cy - nb.y * scale;
      ctx.fillStyle = 'rgba(181,70,110,0.55)';
      ctx.beginPath();
      ctx.arc(px, py, 4 + nb.similarity * 4, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = pal.surface;
      ctx.lineWidth = 1.5;
      ctx.stroke();
    }
  }

  private async createCollection(): Promise<void> {
    if (this.newTitle.trim().length === 0) {
      this.tip = '给收藏夹起个名字';
      return;
    }
    const r = await CommunityService.createCollection(this.newTitle, true);
    if (r.ok) {
      this.newTitle = '';
      this.tip = '收藏夹已创建';
      this.load();
    } else {
      this.tip = r.error;
    }
  }

  build() {
    Column() {
      // 分段切换（与原项目 tab 一致）
      Row({ space: 8 }) {
        Text('公开收藏夹')
          .fontSize(Theme.F_SM)
          .fontColor(this.section === 'collections' ? $r('app.color.on_primary') : $r('app.color.ink_soft'))
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor(this.section === 'collections' ? $r('app.color.primary') : $r('app.color.tint'))
          .borderRadius(Theme.R_FULL)
          .onClick(() => {
            this.section = 'collections';
          })
        Text('发现设置')
          .fontSize(Theme.F_SM)
          .fontColor(this.section === 'settings' ? $r('app.color.on_primary') : $r('app.color.ink_soft'))
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor(this.section === 'settings' ? $r('app.color.primary') : $r('app.color.tint'))
          .borderRadius(Theme.R_FULL)
          .onClick(() => {
            this.section = 'settings';
            if (!this.settingsLoaded) {
              this.loadSettings();
            }
          })
      }
      .width('100%')
      .padding({ left: Theme.S_LG, right: Theme.S_LG, top: Theme.S_MD })

      Scroll() {
        Column({ space: Theme.S_MD }) {
          if (this.section === 'collections') {
            this.collectionsSection()
          } else {
            this.settingsSection()
          }
        }
        .padding(Theme.S_LG)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  collectionsSection() {
    SectionCard({ title: '口味近邻', subtitle: `${this.neighbors.length} 人` }) {
      Column() {
        if (this.neighbors.length === 0) {
          EmptyState({
            title: '暂时没有匹配的同好',
            hint: '收藏或评价更多地点后再来看看'
          })
        } else {
          Canvas(this.ctx)
            .width('100%')
            .height(240)
            .margin({ top: 8 })
            .onReady(() => {
              this.drawStar();
            })
            .onAreaChange((o: Area, nw: Area) => {
              this.starW = Number(nw.width);
              this.starH = Number(nw.height);
              this.drawStar();
            })

          Column() {
            ForEach(this.neighbors, (nb: Neighbor) => {
              Row() {
                Text(nb.username)
                  .fontSize(Theme.F_SM)
                  .fontColor($r('app.color.ink'))
                  .width(96)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${(nb.similarity * 100).toFixed(1)}%`)
                  .fontSize(Theme.F_SM)
                  .fontColor($r('app.color.primary'))
                  .width(56)
                Text(sharedText(nb))
                  .fontSize(Theme.F_CAP)
                  .fontColor($r('app.color.ink_faint'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding({ top: 6, bottom: 6 })
              .border({ width: { bottom: 1 }, color: $r('app.color.line') })
            }, (nb: Neighbor) => nb.id)
          }
          .width('100%')
          .margin({ top: 6 })
        }
      }
    }

    SectionCard({ title: '我的公开收藏夹', subtitle: `${this.collections.length} 个` }) {
      Column({ space: 8 }) {
        Text('收藏夹默认私密，公开后可以让他人看见。')
          .fontSize(Theme.F_SM)
          .fontColor($r('app.color.ink_soft'))
          .width('100%')

        Row({ space: 8 }) {
          TextInput({ text: this.newTitle, placeholder: '新收藏夹名称' })
            .layoutWeight(1)
            .height(38)
            .fontSize(Theme.F_BASE)
            .onChange((v: string) => {
              this.newTitle = v;
            })
          Text('＋ 新建')
            .fontSize(Theme.F_SM)
            .fontColor($r('app.color.on_primary'))
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.primary'))
            .borderRadius(Theme.R_FULL)
            .onClick(() => this.createCollection())
        }
        .width('100%')

        if (this.tip.length > 0) {
          Text(this.tip)
            .fontSize(Theme.F_CAP)
            .fontColor($r('app.color.ink_faint'))
            .width('100%')
        }

        if (this.collections.length === 0) {
          EmptyState({ title: '还没有收藏夹', hint: '新建后可以从你的收藏里挑选地点' })
        } else {
          ForEach(this.collections, (c: Collection) => {
            Row() {
              Column() {
                Text(c.title)
                  .fontSize(Theme.F_BASE)
                  .fontColor($r('app.color.ink'))
                Text(`${collectionCount(c)} 家 · ${c.is_public === true ? '公开' : '私密'}`)
                  .fontSize(Theme.F_CAP)
                  .fontColor($r('app.color.ink_faint'))
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
            .border({ width: { bottom: 1 }, color: $r('app.color.line') })
          }, (c: Collection) => c.id)
        }
      }
    }
  }

  @Builder
  settingsSection() {
    SectionCard({ title: '发现设置', subtitle: `version ${this.consentVersion}` }) {
      Column({ space: 10 }) {
        Text('以下选项默认开启，可以随时关闭。')
          .fontSize(Theme.F_SM)
          .fontColor($r('app.color.ink_soft'))
          .width('100%')

        Text('兴趣标签（逗号分隔，最多 20 个）')
          .fontSize(Theme.F_CAP)
          .fontColor($r('app.color.ink_faint'))
          .width('100%')
        TextInput({ text: this.tagText, placeholder: '例如：粤菜，甜品，宵夜' })
          .height(38)
          .fontSize(Theme.F_BASE)
          .onChange((v: string) => {
            this.tagText = v;
          })

        this.switchRow(
          '允许按我的口味匹配同好，并向其他用户展示我的用户名、兴趣标签和公开收藏夹',
          this.onDiscovery,
          (on: boolean) => {
            this.onDiscovery = on;
          }
        )
        this.switchRow(
          '记录搜索、可见结果、点选、收藏、纠错及定位推断的到访；定位采样仅在前台进行',
          this.onFeedback,
          (on: boolean) => {
            this.onFeedback = on;
          }
        )
        this.switchRow(
          '允许将这些交互记录用于改进用户体验',
          this.onResearch,
          (on: boolean) => {
            this.onResearch = on;
          }
        )

        Column() {
          PrimaryButton({
            label: this.saving ? '保存中…' : '保存设置',
            active: !this.saving,
            onTap: () => {
              this.saveSettings();
            }
          })
        }
        .width('100%')
        .margin({ top: 4 })

        if (this.settingsMsg.length > 0) {
          Text(this.settingsMsg)
            .fontSize(Theme.F_SM)
            .fontColor($r('app.color.ink_soft'))
            .width('100%')
        }
      }
    }

    SectionCard({ title: '交互记录', subtitle: `${this.interactionTotal} 条` }) {
      Column({ space: 10 }) {
        Text(`互动、决策、推断到访及研究证据最长保存 ${this.retentionDays} 天，可随时清除互动记录或撤回研究授权。`)
          .fontSize(Theme.F_SM)
          .fontColor($r('app.color.ink_soft'))
          .lineHeight(19)
          .width('100%')
        Column() {
          PrimaryButton({
            label: '清除交互记录',
            kind: 'ghost',
            onTap: () => {
              this.clearInteractions();
            }
          })
        }
        .width('100%')
      }
    }
  }

  @Builder
  switchRow(label: string, value: boolean, onChange: (on: boolean) => void) {
    Row() {
      Text(label)
        .fontSize(Theme.F_SM)
        .fontColor($r('app.color.ink'))
        .lineHeight(19)
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor($r('app.color.primary'))
        .margin({ left: 8 })
        .onChange((on: boolean) => {
          onChange(on);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }
}

/**
 * 行程页 —— 复刻四段式草稿链路：
 * 写草稿 → 候选补全 → 出预览（preview_hash）→ 提交
 * 提交必须带 hash；hash 缺失/过期/伪造 → 409 preview_stale
 */
import { Theme } from '../common/Theme';
import { addDays, newRequestId, newUuid, today } from '../common/Util';
import { Journey, JourneyCapabilities, JourneyStop, Place, stopCount, stopNames } from '../model/Types';
import {
  DraftContainer, DraftState, JourneyService, JobContainer, PreviewContainer
} from '../service/JourneyService';
import { MiscService, PlaceService } from '../service/Services';
import { EmptyState, LoadingRow, PrimaryButton, SectionCard } from './Widgets';

@Component
export struct JourneyTab {
  @State journeys: Journey[] = [];
  @State caps: JourneyCapabilities | null = null;
  @State loading: boolean = false;
  @State title: string = '';
  @State startDate: string = today();
  @State endDate: string = addDays(today(), 1);
  @State visMode: string = 'private';
  @State stops: JourneyStop[] = [];
  @State log: string[] = [];
  @State stepIndex: number = 0;
  @State submitting: boolean = false;
  @State previewHash: string = '';
  @State draftId: string = '';
  @State errorMsg: string = '';
  @State candidates: Place[] = [];

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    const c = await JourneyService.capabilities();
    if (c.ok && c.data !== null) {
      this.caps = c.data;
    }
    const l = await JourneyService.list();
    if (l.ok && l.data !== null) {
      this.journeys = l.data;
    }
    const p = await PlaceService.nearby(113.22, 23.10, 113.29, 23.14);
    if (p.ok && p.data !== null) {
      this.candidates = p.data.slice(0, 8);
    } else {
      this.candidates = [];
    }
    this.loading = false;
  }

  private logLine(s: string): void {
    const next: string[] = [];
    next.push(`${new Date().toLocaleTimeString()}  ${s}`);
    for (const l of this.log) {
      next.push(l);
    }
    this.log = next.slice(0, 6);
  }

  private addStop(p: Place): void {
    for (const s of this.stops) {
      if (s.place_id === p.id) return;
    }
    const stop: JourneyStop = {
      place_id: p.id,
      name: p.name,
      note: '待补充',
      day: 1,
      order: this.stops.length + 1
    };
    const next: JourneyStop[] = this.stops.slice();
    next.push(stop);
    this.stops = next;
  }

  /**
   * 四段式提交
   */
  private async runPipeline(): Promise<void> {
    if (this.submitting) return;
    if (this.title.trim().length === 0) {
      this.errorMsg = '先给这趟行程起个名字';
      return;
    }
    if (this.stops.length === 0) {
      this.errorMsg = '至少挑一家店';
      return;
    }
    this.submitting = true;
    this.errorMsg = '';
    this.log = [];
    this.stepIndex = 0;

    // 1. 写草稿（客户端生成 UUID，PUT 为 upsert）
    const d: DraftState = JourneyService.newDraft();
    d.id = newUuid();
    d.title = this.title;
    d.start_date = this.startDate;
    d.end_date = this.endDate;
    d.stops = this.stops;
    d.visibility = this.visMode;
    this.draftId = d.id;
    const putRes = await JourneyService.putDraft(d);
    if (!putRes.ok || putRes.data === null) {
      this.errorMsg = putRes.error;
      this.submitting = false;
      return;
    }
    const draft: DraftContainer = putRes.data;
    this.logLine(`草稿已写入 revision=${draft.draft_revision}`);
    this.stepIndex = 1;

    // 2. 候选补全
    const rankRes = await JourneyService.rank(draft.id);
    this.logLine(rankRes.ok ? '候选补全完成' : `候选补全跳过：${rankRes.error}`);
    this.stepIndex = 2;

    // 3. 出预览，拿 preview_hash
    const pvRes = await JourneyService.mapPreview(draft.id, draft.draft_revision);
    if (!pvRes.ok || pvRes.data === null) {
      this.errorMsg = pvRes.error;
      this.submitting = false;
      return;
    }
    const pv: PreviewContainer = pvRes.data;
    this.previewHash = pv.preview_hash;
    this.logLine(`预览已生成 hash=${pv.preview_hash.slice(0, 12)}…`);
    this.stepIndex = 3;

    // 4. 提交（hash 必需）
    const cmRes = await JourneyService.commit(draft.id, pv.preview_hash, newRequestId());
    this.submitting = false;
    if (!cmRes.ok || cmRes.data === null) {
      this.errorMsg = cmRes.error;
      this.logLine(`提交失败：${cmRes.error}`);
      return;
    }
    this.stepIndex = 4;
    this.logLine('提交成功');
    this.title = '';
    this.stops = [];
    this.previewHash = '';
    this.load();
  }

  build() {
    Scroll() {
      Column({ space: Theme.S_MD }) {
        // 新建
        SectionCard({ title: '新建一趟' }) {
          Column({ space: 8 }) {
            TextInput({ text: this.title, placeholder: '行程名字，比如「荔湾半日吃行」' })
              .height(40)
              .fontSize(Theme.F_BASE)
              .onChange((v: string) => {
                this.title = v;
              })

            Row({ space: 8 }) {
              Text(`出发 ${this.startDate}`)
                .fontSize(Theme.F_SM)
                .fontColor($r('app.color.ink_soft'))
                .layoutWeight(1)
                .padding(8)
                .backgroundColor($r('app.color.tint'))
                .borderRadius(Theme.R_SM)
                .onClick(() => {
                  this.startDate = addDays(this.startDate, 1);
                  if (this.endDate < this.startDate) {
                    this.endDate = addDays(this.startDate, 1);
                  }
                })
              Text(`返回 ${this.endDate}`)
                .fontSize(Theme.F_SM)
                .fontColor($r('app.color.ink_soft'))
                .layoutWeight(1)
                .padding(8)
                .backgroundColor($r('app.color.tint'))
                .borderRadius(Theme.R_SM)
                .onClick(() => {
                  this.endDate = addDays(this.endDate, 1);
                })
            }
            .width('100%')

            Row({ space: 8 }) {
              Text(this.visMode === 'public' ? '公开' : '仅自己可见')
                .fontSize(Theme.F_SM)
                .fontColor($r('app.color.primary'))
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .backgroundColor($r('app.color.tint'))
                .borderRadius(Theme.R_FULL)
                .onClick(() => {
                  this.visMode = this.visMode === 'public' ? 'private' : 'public';
                })
              Text(`已选 ${this.stops.length} 家`)
                .fontSize(Theme.F_SM)
                .fontColor($r('app.color.ink_faint'))
                .layoutWeight(1)
            }
            .width('100%')

            // 候选点
            Scroll() {
              Row({ space: 8 }) {
                ForEach(this.candidates, (p: Place) => {
                  Text(p.name)
                    .fontSize(Theme.F_SM)
                    .fontColor(this.picked(p.id) ? $r('app.color.on_primary') : $r('app.color.ink'))
                    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                    .backgroundColor(this.picked(p.id) ? $r('app.color.primary') : $r('app.color.surface_alt'))
                    .borderRadius(Theme.R_FULL)
                    .onClick(() => this.addStop(p))
                }, (p: Place) => p.id.toString())
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')

            if (this.stops.length > 0) {
              Column({ space: 4 }) {
                ForEach(this.stops, (s: JourneyStop) => {
                  Row() {
                    Text(`${s.order}`)
                      .fontSize(Theme.F_CAP)
                      .fontColor($r('app.color.on_primary'))
                      .width(18)
                      .height(18)
                      .textAlign(TextAlign.Center)
                      .backgroundColor($r('app.color.primary'))
                      .borderRadius(9)
                    Text(s.name)
                      .fontSize(Theme.F_SM)
                      .fontColor($r('app.color.ink'))
                      .margin({ left: 8 })
                      .layoutWeight(1)
                    Text('移除')
                      .fontSize(Theme.F_CAP)
                      .fontColor($r('app.color.danger'))
                      .onClick(() => {
                        this.removeStop(s.place_id);
                      })
                  }
                  .width('100%')
                  .padding({ top: 3, bottom: 3 })
                }, (s: JourneyStop) => `${s.place_id}`)
              }
              .width('100%')
              .margin({ top: 4 })
            }

            Column() {
              PrimaryButton({
                label: this.submitting ? '提交中…' : '生成并提交',
                active: !this.submitting,
                onTap: () => this.runPipeline()
              })
            }
            .width('100%')
            .margin({ top: 4 })

            if (this.errorMsg.length > 0) {
              Text(this.errorMsg)
                .fontSize(Theme.F_SM)
                .fontColor($r('app.color.danger'))
                .width('100%')
            }

            if (this.log.length > 0) {
              Column({ space: 2 }) {
                ForEach(this.log, (l: string) => {
                  Text(l)
                    .fontSize(Theme.F_CAP)
                    .fontColor($r('app.color.ink_faint'))
                    .width('100%')
                }, (l: string, i: number) => `${i}-${l}`)
              }
              .width('100%')
              .padding(8)
              .backgroundColor($r('app.color.surface_alt'))
              .borderRadius(Theme.R_SM)
            }
          }
        }

        // 已有行程
        SectionCard({ title: '我的行程', subtitle: `${this.journeys.length} 条` }) {
          Column() {
            if (this.loading) {
              LoadingRow()
            } else if (this.journeys.length === 0) {
              EmptyState({ title: '还没有行程', hint: '上面挑几家店，就能生成一趟' })
            } else {
              ForEach(this.journeys, (j: Journey) => {
                Column() {
                  Row() {
                    Text(j.title)
                      .fontSize(Theme.F_BASE)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.ink'))
                      .layoutWeight(1)
                    Text(j.visibility === 'public' ? '公开' : '私密')
                      .fontSize(Theme.F_CAP)
                      .fontColor($r('app.color.ink_faint'))
                  }
                  .width('100%')
                  Text(`${j.start_date} → ${j.end_date} · ${stopCount(j)} 站 · revision ${j.revision}`)
                    .fontSize(Theme.F_CAP)
                    .fontColor($r('app.color.ink_faint'))
                    .width('100%')
                    .margin({ top: 2 })
                  if (stopCount(j) > 0) {
                    Text(stopNames(j))
                      .fontSize(Theme.F_SM)
                      .fontColor($r('app.color.ink_soft'))
                      .width('100%')
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 4 })
                  }
                }
                .width('100%')
                .padding({ top: 8, bottom: 8 })
                .border({ width: { bottom: 1 }, color: $r('app.color.line') })
              }, (j: Journey) => j.id)
            }
          }
        }
      }
      .padding(Theme.S_LG)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }

  private removeStop(placeId: number): void {
    const out: JourneyStop[] = [];
    let i = 0;
    for (const s of this.stops) {
      if (s.place_id !== placeId) {
        i++;
        s.order = i;
        out.push(s);
      }
    }
    this.stops = out;
  }

  private picked(placeId: number): boolean {
    for (const s of this.stops) {
      if (s.place_id === placeId) return true;
    }
    return false;
  }

  @Builder
  capChip(label: string, on: boolean) {
    Text(`${label} ${on ? '开' : '关'}`)
      .fontSize(Theme.F_CAP)
      .fontColor(on ? $r('app.color.on_primary') : $r('app.color.ink_faint'))
      .backgroundColor(on ? $r('app.color.primary') : $r('app.color.tint'))
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .borderRadius(Theme.R_FULL)
  }
}

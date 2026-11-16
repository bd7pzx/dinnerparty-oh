/** 收藏页：我收藏的地点 + 收藏夹管理（独立成页） */
import { Theme } from '../common/Theme';
import { formatCost, truncate } from '../common/Util';
import { Collection, Place, addressOf, collectionCount, splitCategory } from '../model/Types';
import { CollectionContainer, CommunityService, PlaceService } from '../service/Services';
import { EmptyState, LoadingRow, PrimaryButton, SectionCard } from './Widgets';
import { PlaceDetail } from './PlaceDetail';

@Component
export struct FavoritesTab {
  @State favorites: Place[] = [];
  @State collections: Collection[] = [];
  @State loading: boolean = false;
  @State tip: string = '';
  @State newTitle: string = '';
  @State selected: Place | null = null;
  @State showDetail: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    const f = await PlaceService.favorites();
    if (f.ok && f.data !== null) {
      this.favorites = f.data;
    } else {
      this.favorites = [];
      this.tip = f.status === 401 ? '登录后可查看收藏' : `收藏加载失败：${f.error}`;
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
  }

  private async createCollection(): Promise<void> {
    const title = this.newTitle.trim();
    if (title.length === 0) {
      this.tip = '给收藏夹起个名字';
      return;
    }
    const r = await CommunityService.createCollection(title, false);
    if (r.ok) {
      this.newTitle = '';
      this.tip = '收藏夹已创建';
      this.load();
    } else {
      this.tip = r.error;
    }
  }

  private async removeCollection(id: string): Promise<void> {
    const r = await CommunityService.deleteCollection(id);
    if (r.ok) {
      this.tip = '收藏夹已删除';
      this.load();
    } else {
      this.tip = r.error;
    }
  }

  private async cancelFavorite(p: Place): Promise<void> {
    const r = await PlaceService.removeFavorite(p.id);
    if (r.ok) {
      this.tip = `已取消收藏「${p.name}」`;
      this.load();
    } else {
      this.tip = r.error;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Scroll() {
        Column({ space: Theme.S_MD }) {
          SectionCard({ title: '我收藏的地点', subtitle: `${this.favorites.length} 家` }) {
            Column() {
              if (this.loading) {
                LoadingRow({ text: '正在加载收藏…' })
              } else if (this.favorites.length === 0) {
                EmptyState({
                  title: '还没有收藏地点',
                  hint: '在地点详情里点「收藏」，会出现在这里'
                })
              } else {
                ForEach(this.favorites, (p: Place) => {
                  Row() {
                    Column() {
                      Text(truncate(p.name, 16))
                        .fontSize(Theme.F_BASE)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.ink'))
                      Text(`${splitCategory(p.category).join(' / ')}` +
                        (p.rating_average !== undefined && p.rating_average > 0
                          ? ` · ${p.rating_average.toFixed(1)} 分` : '') +
                        (p.per_person_cost !== undefined && p.per_person_cost !== null
                          ? ` · ${formatCost(p.per_person_cost)}` : ''))
                        .fontSize(Theme.F_CAP)
                        .fontColor($r('app.color.ink_faint'))
                        .margin({ top: 2 })
                      Text(truncate(addressOf(p), 24))
                        .fontSize(Theme.F_SM)
                        .fontColor($r('app.color.ink_soft'))
                        .margin({ top: 3 })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Text('取消')
                      .fontSize(Theme.F_CAP)
                      .fontColor($r('app.color.danger'))
                      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                      .backgroundColor($r('app.color.tint'))
                      .borderRadius(Theme.R_FULL)
                      .onClick(() => {
                        this.cancelFavorite(p);
                      })
                  }
                  .width('100%')
                  .padding({ top: 8, bottom: 8 })
                  .border({ width: { bottom: 1 }, color: $r('app.color.line') })
                  .onClick(() => {
                    this.selected = p;
                    this.showDetail = true;
                  })
                }, (p: Place) => `${p.id}`)
              }
            }
          }

          SectionCard({
            title: '收藏夹',
            subtitle: `${this.collections.length} 个`
          }) {
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
                    Text('删除')
                      .fontSize(Theme.F_CAP)
                      .fontColor($r('app.color.danger'))
                      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                      .backgroundColor($r('app.color.tint'))
                      .borderRadius(Theme.R_FULL)
                      .onClick(() => {
                        this.removeCollection(c.id);
                      })
                  }
                  .width('100%')
                  .padding({ top: 8, bottom: 8 })
                  .border({ width: { bottom: 1 }, color: $r('app.color.line') })
                }, (c: Collection) => c.id)
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

      if (this.showDetail && this.selected !== null) {
        Column() {
          PlaceDetail({
            place: this.selected,
            onClose: () => {
              this.showDetail = false;
              this.load();
            }
          })
        }
        .width('100%')
        .height('86%')
        .backgroundColor($r('app.color.bg'))
        .borderRadius({ topLeft: Theme.R_XL, topRight: Theme.R_XL })
        .shadow(Theme.floatShadow())
      }
    }
    .width('100%')
    .height('100%')
  }
}

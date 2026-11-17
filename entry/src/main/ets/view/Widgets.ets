/** 通用 UI 组件 */
import { Theme } from '../common/Theme';

@Builder
export function hairline(color: string) {
  Divider()
    .strokeWidth(1)
    .color(color)
    .opacity(0.6)
}

@Component
export struct SectionCard {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  emptyContent() {
  }

  build() {
    Column() {
      if (this.title.length > 0) {
        Row() {
          Text(this.title)
            .fontSize(Theme.F_MD)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink'))
            .layoutWeight(1)
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(Theme.F_SM)
              .fontColor($r('app.color.ink_faint'))
          }
        }
        .width('100%')
        .margin({ bottom: Theme.S_MD })
      }
      this.content()
    }
    .width('100%')
    .padding(Theme.S_LG)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.R_LG)
    .shadow(Theme.cardShadow())
  }
}

@Component
export struct PillTag {
  @Prop text: string = '';
  @Prop active: boolean = false;
  /** 0 普通；1 选中（包含筛选）；2 排除筛选 */
  @Prop state: number = 0;
  tone: string = 'primary';
  onTap: () => void = () => {
  };

  private bg(): ResourceColor {
    if (this.state === 1) {
      return $r('app.color.primary');
    }
    if (this.state === 2) {
      return $r('app.color.danger');
    }
    return $r('app.color.tint');
  }

  private fg(): ResourceColor {
    if (this.state === 1) {
      return $r('app.color.on_primary');
    }
    if (this.state === 2) {
      return Color.White;
    }
    return $r('app.color.ink_soft');
  }

  build() {
    Text(this.text)
      .fontSize(Theme.F_SM)
      .fontColor(this.fg())
      .backgroundColor(this.bg())
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(Theme.R_FULL)
      .border({
        width: this.state === 2 ? 1 : 0,
        color: this.state === 2 ? Color.White : Color.Transparent
      })
      .onClick(() => {
        this.onTap();
      })
  }
}

@Component
export struct PrimaryButton {
  label: string = '';
  active: boolean = true;
  kind: string = 'primary';
  onTap: () => void = () => {
  };

  build() {
    Text(this.label)
      .fontSize(Theme.F_MD)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.kind === 'ghost' ? $r('app.color.primary') : $r('app.color.on_primary'))
      .textAlign(TextAlign.Center)
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .backgroundColor(this.kind === 'ghost' ? $r('app.color.tint') :
        (this.active ? $r('app.color.primary') : $r('app.color.line')))
      .borderRadius(Theme.R_FULL)
      .opacity(this.active ? 1 : 0.6)
      .onClick(() => {
        if (this.active) {
          this.onTap();
        }
      })
  }
}

@Component
export struct EmptyState {
  title: string = '还没有内容';
  hint: string = '';

  build() {
    Column() {
      Text('○')
        .fontSize(34)
        .fontColor($r('app.color.line'))
      Text(this.title)
        .fontSize(Theme.F_BASE)
        .fontColor($r('app.color.ink_soft'))
        .margin({ top: 8 })
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(Theme.F_SM)
          .fontColor($r('app.color.ink_faint'))
          .margin({ top: 4 })
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .padding({ top: 40, bottom: 40 })
    .justifyContent(FlexAlign.Center)
  }
}

@Component
export struct LoadingRow {
  text: string = '加载中…';

  build() {
    Row() {
      LoadingProgress()
        .width(18)
        .height(18)
        .color($r('app.color.primary'))
      Text(this.text)
        .fontSize(Theme.F_SM)
        .fontColor($r('app.color.ink_faint'))
        .margin({ left: 8 })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding(16)
  }
}

/** 评分分布条 */
@Component
export struct DistributionBar {
  label: string = '';
  count: number = 0;
  total: number = 1;
  color: string = '#C0433F';

  build() {
    Row() {
      Text(this.label)
        .fontSize(Theme.F_CAP)
        .fontColor($r('app.color.ink_faint'))
        .width(28)
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(7)
          .backgroundColor($r('app.color.tint'))
          .borderRadius(4)
        Row()
          .width(`${Math.round(this.total > 0 ? (this.count / this.total) * 100 : 0)}%`)
          .height(7)
          .backgroundColor(this.color)
          .borderRadius(4)
      }
      .layoutWeight(1)
      .height(7)

      Text(`${this.count}`)
        .fontSize(Theme.F_CAP)
        .fontColor($r('app.color.ink_faint'))
        .width(26)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .margin({ bottom: 5 })
  }
}

@Component
export struct MetricCell {
  label: string = '';
  value: string = '';
  hint: string = '';

  build() {
    Column() {
      Text(this.value)
        .fontSize(Theme.F_LG)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.ink'))
      Text(this.label)
        .fontSize(Theme.F_CAP)
        .fontColor($r('app.color.ink_faint'))
        .margin({ top: 2 })
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(Theme.F_CAP)
          .fontColor($r('app.color.primary'))
          .margin({ top: 2 })
      }
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }
}

/** 顶部提示条 */
@Component
export struct NoticeBar {
  text: string = '';
  onClose: () => void = () => {
  };

  build() {
    Row() {
      Text('!')
        .fontSize(Theme.F_SM)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.on_primary'))
        .width(18)
        .height(18)
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.primary'))
        .borderRadius(9)
      Text(this.text)
        .fontSize(Theme.F_SM)
        .fontColor($r('app.color.ink_soft'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 8, right: 8 })
      Text('×')
        .fontSize(Theme.F_MD)
        .fontColor($r('app.color.ink_faint'))
        .onClick(() => this.onClose())
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.tint'))
    .borderRadius(Theme.R_MD)
  }
}

export function paletteOf(): ResourceColor {
  return $r('app.color.primary');
}

/**
 * TabBar.ets
 * -----------
 * 底部导航栏组件
 */

import router from "@ohos.router";
import { AppColors } from "../theme/Theme";

interface TabItem {
  label: string;
  icon: string;
  route: string;
}

@Component
export struct TabBar {
  @Prop activeIndex: number = 0;
  private tabs: TabItem[] = [
    { label: "聊天", icon: "💬", route: "pages/Index" },
    { label: "记忆", icon: "🧠", route: "pages/MemoryPage" },
    { label: "决策", icon: "🤔", route: "pages/DecisionPage" },
    { label: "洞察", icon: "📊", route: "pages/InsightsPage" },
  ];

  build() {
    Row() {
      ForEach(this.tabs, (tab: TabItem, idx: number) => {
        Column() {
          Text(tab.icon)
            .fontSize(22)
            .opacity(this.activeIndex === idx ? 1.0 : 0.4)
          Text(tab.label)
            .fontSize(11)
            .fontColor(this.activeIndex === idx ? AppColors.PRIMARY : AppColors.TEXT_TERTIARY)
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .height(56)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          if (idx !== this.activeIndex) {
            router.pushUrl({ url: tab.route });
          }
        })
      })
    }
    .width("100%")
    .backgroundColor(AppColors.BG_CARD)
    .border({ width: { top: 0.5 }, color: AppColors.BORDER })
  }
}

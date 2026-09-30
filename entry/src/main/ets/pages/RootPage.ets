/**
 * 根页面（RootPage）—— Navigation 导航容器
 *
 * 架构：EntryAbility → RootPage(Navigation + NavPathStack) → 各业务页（NavDestination）
 * 页面不直接使用 router；跳转统一走 pathStack（@Provide/@Consume 共享）。
 * 参数传递：RouteParams（@Provide 共享对象，跳转前设置字段）。
 */
import { RouteParams } from '../model/Model';
import { Index } from './Index';
import { DeviceList } from './DeviceList';
import { SettingsPage } from './SettingsPage';
import { SharePage } from './SharePage';
import { TerminalPage } from './TerminalPage';
import { PreviewPage } from './PreviewPage';
import { KeymapPage } from './KeymapPage';
import { TagsPage } from './TagsPage';
import { PeripheralPage } from './PeripheralPage';
import { ShareManagePage } from './ShareManagePage';
import { DashboardPage } from './DashboardPage';
import { TasksPage } from './TasksPage';
import { FileCenterPage } from './FileCenterPage';
import { ArkWebView } from './ArkWebView';

@Entry
@Component
export struct RootPage {
  @Provide('pathStack') pathStack: NavPathStack = new NavPathStack();
  @Provide('routeParams') routeParams: RouteParams = new RouteParams();

  @Builder
  pageMap(name: string) {
    if (name === 'DeviceList') {
      NavDestination() {
        DeviceList()
      }
      .title('设备列表')
      .hideTitleBar(true)
    } else if (name === 'Settings') {
      NavDestination() {
        SettingsPage()
      }
      .title('设置')
    } else if (name === 'Share') {
      NavDestination() {
        SharePage()
      }
      .title('卡密连接')
      .hideTitleBar(true)
    } else if (name === 'Terminal') {
      NavDestination() {
        TerminalPage()
      }
      .title('终端')
      .hideTitleBar(true)
    } else if (name === 'Preview') {
      NavDestination() {
        PreviewPage()
      }
      .title('设备预览')
      .hideTitleBar(true)
    } else if (name === 'Keymap') {
      NavDestination() {
        KeymapPage()
      }
      .title('键位映射')
      .hideTitleBar(true)
    } else if (name === 'Tags') {
      NavDestination() {
        TagsPage()
      }
      .title('标签管理')
      .hideTitleBar(true)
    } else if (name === 'Peripheral') {
      NavDestination() {
        PeripheralPage()
      }
      .title('外设模拟')
      .hideTitleBar(true)
    } else if (name === 'ShareManage') {
      NavDestination() {
        ShareManagePage()
      }
      .title('分享卡密')
      .hideTitleBar(true)
    } else if (name === 'Dashboard') {
      NavDestination() {
        DashboardPage()
      }
      .title('监控大盘')
      .hideTitleBar(true)
    } else if (name === 'Tasks') {
      NavDestination() {
        TasksPage()
      }
      .title('群控任务')
      .hideTitleBar(true)
    } else if (name === 'FileCenter') {
      NavDestination() {
        FileCenterPage()
      }
      .title('文件中心')
      .hideTitleBar(true)
    } else if (name === 'ArkWebView') {
      NavDestination() {
        ArkWebView()
      }
      .title('云手机控制')
    }
  }

  build() {
    Navigation(this.pathStack) {
      Index()
    }
    .navDestination(this.pageMap)
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .width('100%')
    .height('100%')
  }
}

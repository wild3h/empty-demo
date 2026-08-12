# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 技术栈

- **语言与构建**：Kotlin、少量 Java、Gradle Kotlin DSL、KSP、Kotlin Serialization、AndroidAOP。
- **Android UI**：AndroidX AppCompat/Core/Activity、Material Components、ConstraintLayout、XML、Data Binding、View Binding、Lottie、SmartRefreshLayout。
- **架构与异步**：轻量 MVVM、AndroidX Lifecycle/ViewModel/LiveData、Kotlin Coroutines；未使用 Hilt、Dagger 或 Koin。
- **网络**：Retrofit 2.9、OkHttp 4.12、Gson、Java-WebSocket。
- **本地数据**：Room 2.8.4（KSP）、MMKV。
- **图片**：Glide。

## 架构与数据流

项目采用无依赖注入框架

### `app` 模块

主要包职责：

- `ui`：Activity/Fragment 页面；`ui/viewmodel` 保存页面状态和动作。
- `net`：Retrofit API、网络单例和拦截器。
- `entity`：接口响应及 Room 实体。
- `dao`：Room 数据库和 DAO。
- `data`：进程级状态及 Repository。
- `utils`：MMKV、埋点、SDK 生命周期、配置和报告工具。
- `adapter`、`widget`：列表及自定义展示组件。

## 常见业务功能名称
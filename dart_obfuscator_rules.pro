# lib/app/config/目录下所有文件的类都不混淆
-keep class lib/app/config/** { *; }
-keep class core/** { *; }
# 所有继承BaseView的类都不混淆
-keep class * extends BaseView
# 只保留某个方法，其他可以混淆
-keep class lib/app/Controller {
    String getMsg(List<int> contents, int key, bool hasEmoji);  # 保留指定方法
}
-rename-files no



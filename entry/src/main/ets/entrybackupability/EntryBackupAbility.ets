/**
 * EntryBackupAbility.ets
 * -----------------------
 * 备份恢复扩展能力。
 *
 * 用于系统备份/恢复时保存和恢复应用数据：
 *   - SQLite 记忆数据库（zhixin_memory.db）
 *   - Preferences 离线队列配置
 *
 * 不备份的内容：
 *   - 缓存文件
 *   - 临时文件
 *   - 行为日志原始数据（太大）
 */

import Ability from "@ohos.app.ability.BackupExtensionAbility";
import fileUri from "@ohos.file.fileuri";
import fs from "@ohos.file.fs";

export default class EntryBackupAbility extends Ability {
  onBackup(): Promise<void> {
    // 备份时：导出数据库文件 URI
    console.info("[Backup] 开始备份应用数据");
    // TODO: 实现备份逻辑
    return Promise.resolve();
  }

  onRestore(backupInfo: { [key: string]: Object }): Promise<void> {
    // 恢复时：导入数据库文件
    console.info("[Backup] 开始恢复应用数据");
    // TODO: 实现恢复逻辑
    return Promise.resolve();
  }
}

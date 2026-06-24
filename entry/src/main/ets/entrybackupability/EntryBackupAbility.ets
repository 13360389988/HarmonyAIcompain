import { BackupExtensionAbility } from "@kit.BackupKit";

export default class EntryBackupAbility extends BackupExtensionAbility {
  onBackup(): void {
    console.info("[Backup] EntryBackupAbility onBackup");
  }

  onRestore(): void {
    console.info("[Backup] EntryBackupAbility onRestore");
  }
}

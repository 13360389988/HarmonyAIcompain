import { UIAbility } from "@kit.AbilityKit";

export default class EntryBackupAbility extends UIAbility {
  onBackup(): void {
    console.info("[Backup] EntryBackupAbility onBackup");
  }

  onRestore(): void {
    console.info("[Backup] EntryBackupAbility onRestore");
  }
}

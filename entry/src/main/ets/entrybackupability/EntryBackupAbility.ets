import UIAbility from "@ohos.app.ability.UIAbility";

export default class EntryBackupAbility extends UIAbility {
  onCreate(): void {
    console.info("[Backup] EntryBackupAbility created");
  }

  onDestroy(): void {
    console.info("[Backup] EntryBackupAbility destroyed");
  }
}

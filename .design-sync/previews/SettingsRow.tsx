import * as React from "react";
import { SettingsRow, Switch, Button, SegmentedControl } from "@glancekit/design-system";

export function WithSwitch() {
  return (
    <div style={{ width: 340 }}>
      <SettingsRow title="Show change as percent" detail="Otherwise shown as an absolute price move.">
        <Switch checked />
      </SettingsRow>
    </div>
  );
}

export function WithButton() {
  return (
    <div style={{ width: 340 }}>
      <SettingsRow title="Keyboard shortcut">
        <Button variant="secondary" size="small">Record…</Button>
      </SettingsRow>
    </div>
  );
}

export function FillingControl() {
  const [v, setV] = React.useState("1M");
  return (
    <div style={{ width: 340 }}>
      <SettingsRow title="Default range" fillControl>
        <SegmentedControl options={["1D", "1W", "1M", "1Y"]} value={v} onChange={setV} />
      </SettingsRow>
    </div>
  );
}

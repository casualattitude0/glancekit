import * as React from "react";
import { Card, SettingsRow, Switch, SegmentedControl, Button } from "@glancekit/design-system";

export function SettingsCard() {
  const [density, setDensity] = React.useState("Regular");
  return (
    <div style={{ width: 360 }}>
      <Card title="General">
        <SettingsRow title="Launch at login">
          <Switch checked />
        </SettingsRow>
        <SettingsRow title="Show in menu bar" detail="A compact readout beside the clock.">
          <Switch checked />
        </SettingsRow>
        <SettingsRow title="Density" fillControl>
          <SegmentedControl
            options={["Compact", "Regular", "Expanded"]}
            value={density}
            onChange={setDensity}
          />
        </SettingsRow>
      </Card>
    </div>
  );
}

export function WithAction() {
  return (
    <div style={{ width: 360 }}>
      <Card title="Data source">
        <SettingsRow title="Provider" detail="Quotes refresh every 60 seconds.">
          <Button variant="secondary" size="small">Change…</Button>
        </SettingsRow>
        <SettingsRow title="Clear cache">
          <Button variant="destructive" size="small">Clear</Button>
        </SettingsRow>
      </Card>
    </div>
  );
}

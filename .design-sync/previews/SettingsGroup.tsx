import * as React from "react";
import { SettingsGroup, SettingsRow, Switch } from "@glancekit/design-system";

export function Notifications() {
  return (
    <div style={{ width: 360 }}>
      <SettingsGroup title="Alerts">
        <SettingsRow title="Price target hit">
          <Switch checked />
        </SettingsRow>
        <SettingsRow title="Daily summary" detail="Delivered at market close.">
          <Switch checked={false} />
        </SettingsRow>
        <SettingsRow title="Play sound">
          <Switch checked />
        </SettingsRow>
      </SettingsGroup>
    </div>
  );
}

export function TwoGroups() {
  return (
    <div style={{ width: 360, display: "flex", flexDirection: "column", gap: 18 }}>
      <SettingsGroup title="Appearance">
        <SettingsRow title="Use accent colour">
          <Switch checked />
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title="Privacy">
        <SettingsRow title="Share anonymous usage">
          <Switch checked={false} />
        </SettingsRow>
      </SettingsGroup>
    </div>
  );
}

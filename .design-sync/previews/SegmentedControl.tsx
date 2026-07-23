import * as React from "react";
import { SegmentedControl } from "@glancekit/design-system";

export function Ranges() {
  const [v, setV] = React.useState("1M");
  return <SegmentedControl options={["1D", "1W", "1M", "1Y"]} value={v} onChange={setV} />;
}

export function Density() {
  const [v, setV] = React.useState("Regular");
  return (
    <SegmentedControl
      options={["Compact", "Regular", "Expanded"]}
      value={v}
      onChange={setV}
    />
  );
}

export function TwoUp() {
  const [v, setV] = React.useState("gainers");
  return (
    <SegmentedControl
      options={[
        { label: "Gainers", value: "gainers" },
        { label: "Losers", value: "losers" },
      ]}
      value={v}
      onChange={setV}
    />
  );
}

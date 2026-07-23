import * as React from "react";

export interface SwitchProps {
  /** Whether the switch is on. */
  checked?: boolean;
  /** Called with the next checked value when toggled. */
  onChange?: (checked: boolean) => void;
  /** Optional trailing label rendered beside the track. */
  label?: React.ReactNode;
  /** Dims the control and blocks interaction. */
  disabled?: boolean;
}

/**
 * The macOS toggle switch — an accent-filled pill track with a sliding thumb.
 * The single control for every on/off setting (see SettingsToggleRow).
 */
export function Switch({ checked = false, onChange, label, disabled }: SwitchProps) {
  return (
    <label
      className="gk-switch"
      data-checked={checked}
      data-disabled={disabled || undefined}
    >
      <span className="gk-switch__track">
        <span className="gk-switch__thumb" />
      </span>
      <input
        type="checkbox"
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange?.(e.target.checked)}
        style={{ position: "absolute", opacity: 0, width: 0, height: 0 }}
      />
      {label != null && <span>{label}</span>}
    </label>
  );
}

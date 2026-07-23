import * as React from "react";

export interface SliderProps {
  /** Current value. */
  value?: number;
  /** Minimum value (default 0). */
  min?: number;
  /** Maximum value (default 100). */
  max?: number;
  /** Step increment (default 1). */
  step?: number;
  /** Called with the new numeric value as the knob moves. */
  onChange?: (value: number) => void;
  /** Dims the control and blocks interaction. */
  disabled?: boolean;
}

/**
 * A horizontal slider with the accent-filled track and a round knob. The filled
 * portion is driven by the current value, so the control reads at a glance.
 */
export function Slider({
  value = 50,
  min = 0,
  max = 100,
  step = 1,
  onChange,
  disabled,
}: SliderProps) {
  const pct = max > min ? ((value - min) / (max - min)) * 100 : 0;
  return (
    <span
      className="gk-slider"
      data-disabled={disabled || undefined}
      style={{ ["--gk-slider-fill" as string]: `${pct}%` }}
    >
      <input
        className="gk-slider__input"
        type="range"
        value={value}
        min={min}
        max={max}
        step={step}
        disabled={disabled}
        onChange={(e) => onChange?.(Number(e.target.value))}
      />
    </span>
  );
}

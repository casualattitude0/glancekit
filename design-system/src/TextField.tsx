import * as React from "react";

export interface TextFieldProps
  extends Omit<React.InputHTMLAttributes<HTMLInputElement>, "className" | "size"> {
  /** Caption stacked above the field, matching SettingsKit's LabeledField. */
  label?: string;
  /** Render as a password field. */
  secure?: boolean;
}

/**
 * A bezeled single-line text (or secure) field with an optional stacked label —
 * the form-entry control used on the key/URL settings pages.
 */
export function TextField({ label, secure, type, ...rest }: TextFieldProps) {
  return (
    <label className="gk-field">
      {label && <span className="gk-field__label">{label}</span>}
      <input
        className="gk-field__input"
        type={type ?? (secure ? "password" : "text")}
        {...rest}
      />
    </label>
  );
}

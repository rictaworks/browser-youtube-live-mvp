import { act, fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { StrictMode, useLayoutEffect, useRef, useState } from "react";
import { ConfirmDialog, type ConfirmDialogProps } from "./ConfirmDialog";

// 確認用のダイアログ（ネイティブの confirm の代わり）。role=alertdialog・フォーカストラップ・ESC・フォーカスの復帰。
// 画面の文言は、呼び出し側が渡す（この部品は、文言を持たない）。

function dialogProps(overrides: Partial<ConfirmDialogProps> = {}): ConfirmDialogProps {
  return {
    title: "dialog-title",
    description: "dialog-description",
    confirmLabel: "confirm-action",
    confirmBusyLabel: "confirm-busy",
    cancelLabel: "cancel-action",
    busy: false,
    onConfirm: jest.fn(),
    onCancel: jest.fn(),
    ...overrides,
  };
}

describe("ConfirmDialog: 構造（アクセシビリティ）", () => {
  it("role=alertdialog・aria-modal。題（h2）を名前に、説明を、説明（aria-describedby）にする", () => {
    render(<ConfirmDialog {...dialogProps()} />);

    const dialog = screen.getByRole("alertdialog", { name: "dialog-title" });

    expect(dialog).toHaveAttribute("aria-modal", "true");
    expect(dialog).toHaveAccessibleDescription("dialog-description");
    expect(screen.getByRole("heading", { level: 2, name: "dialog-title" })).toBeInTheDocument();
  });

  it("キャンセルと確認のボタンを持つ。ボタンの文言は、渡されたもの", () => {
    render(<ConfirmDialog {...dialogProps()} />);

    expect(screen.getByRole("button", { name: "cancel-action" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "confirm-action" })).toBeInTheDocument();
  });

  it("失敗の通知（notice）を、ダイアログの中に出せる", () => {
    render(<ConfirmDialog {...dialogProps({ notice: <p role="alert">failure-notice</p> })} />);

    expect(screen.getByRole("alertdialog")).toContainElement(screen.getByRole("alert"));
  });

  it("ネイティブの confirm・alert を、使わない", async () => {
    const user = userEvent.setup();
    const nativeConfirm = jest.spyOn(window, "confirm").mockImplementation(() => true);
    const nativeAlert = jest.spyOn(window, "alert").mockImplementation(() => undefined);
    render(<ConfirmDialog {...dialogProps()} />);

    await user.click(screen.getByRole("button", { name: "confirm-action" }));
    await user.keyboard("{Escape}");

    expect(nativeConfirm).not.toHaveBeenCalled();
    expect(nativeAlert).not.toHaveBeenCalled();
    nativeConfirm.mockRestore();
    nativeAlert.mockRestore();
  });
});

describe("ConfirmDialog: 操作", () => {
  it("開いた直後は、取り消せる側（キャンセル）にフォーカスがある", () => {
    render(<ConfirmDialog {...dialogProps()} />);

    expect(screen.getByRole("button", { name: "cancel-action" })).toHaveFocus();
  });

  it("確認を押すと onConfirm、キャンセルを押すと onCancel を、1 回ずつ呼ぶ", async () => {
    const user = userEvent.setup();
    const props = dialogProps();
    render(<ConfirmDialog {...props} />);

    await user.click(screen.getByRole("button", { name: "confirm-action" }));
    expect(props.onConfirm).toHaveBeenCalledTimes(1);
    expect(props.onCancel).not.toHaveBeenCalled();

    await user.click(screen.getByRole("button", { name: "cancel-action" }));
    expect(props.onCancel).toHaveBeenCalledTimes(1);
  });

  it("Escape で、onCancel を呼ぶ（フォーカスが、ダイアログの外にあっても）", async () => {
    const user = userEvent.setup();
    const props = dialogProps();
    render(<ConfirmDialog {...props} />);

    await user.keyboard("{Escape}");

    expect(props.onCancel).toHaveBeenCalledTimes(1);
  });

  it("背景（オーバーレイ）をクリックしても、閉じない（誤って取り消さない）", async () => {
    const user = userEvent.setup();
    const props = dialogProps();
    const { container } = render(<ConfirmDialog {...props} />);

    await user.click(container.firstElementChild as HTMLElement);

    expect(props.onCancel).not.toHaveBeenCalled();
    expect(props.onConfirm).not.toHaveBeenCalled();
  });

  it("確認のボタンは、キーボード（Tab → Enter）で操作できる", async () => {
    const user = userEvent.setup();
    const props = dialogProps();
    render(<ConfirmDialog {...props} />);

    await user.tab();
    expect(screen.getByRole("button", { name: "confirm-action" })).toHaveFocus();
    await user.keyboard("{Enter}");

    expect(props.onConfirm).toHaveBeenCalledTimes(1);
  });
});

describe("ConfirmDialog: フォーカストラップ", () => {
  it("Tab は、ダイアログの中を循環する（確認の次は、最初のキャンセルへ戻る）", async () => {
    const user = userEvent.setup();
    render(
      <>
        <button type="button">outside-before</button>
        <ConfirmDialog {...dialogProps()} />
        <button type="button">outside-after</button>
      </>,
    );

    await user.tab();
    expect(screen.getByRole("button", { name: "confirm-action" })).toHaveFocus();
    await user.tab();
    expect(screen.getByRole("button", { name: "cancel-action" })).toHaveFocus();
    await user.tab();
    expect(screen.getByRole("button", { name: "confirm-action" })).toHaveFocus();
  });

  it("Shift+Tab も、循環する（最初のキャンセルの前は、最後の確認）", async () => {
    const user = userEvent.setup();
    render(<ConfirmDialog {...dialogProps()} />);

    await user.tab({ shift: true });

    expect(screen.getByRole("button", { name: "confirm-action" })).toHaveFocus();
  });

  it("ダイアログの外へフォーカスが移ったら、ダイアログの中へ戻す", async () => {
    render(
      <>
        <button type="button">outside</button>
        <ConfirmDialog {...dialogProps()} />
      </>,
    );

    act(() => screen.getByRole("button", { name: "outside" }).focus());

    expect(screen.getByRole("alertdialog")).toContainElement(document.activeElement as HTMLElement);
  });
});

describe("ConfirmDialog: 処理中（確認の API を呼んでいる間）", () => {
  it("確認の文言を進行形（busyLabel）に替え、aria-busy にする。二重に押しても、onConfirm を呼ばない", async () => {
    const user = userEvent.setup();
    const props = dialogProps({ busy: true });
    render(<ConfirmDialog {...props} />);

    const confirm = screen.getByRole("button", { name: "confirm-busy" });
    await user.click(confirm);
    await user.dblClick(confirm);

    expect(confirm).toHaveAttribute("aria-busy", "true");
    expect(props.onConfirm).not.toHaveBeenCalled();
  });

  it("キャンセルのボタンは無効になり、Escape でも閉じない（処理の途中で、閉じない）", async () => {
    const user = userEvent.setup();
    const props = dialogProps({ busy: true });
    render(<ConfirmDialog {...props} />);

    await user.keyboard("{Escape}");

    expect(screen.getByRole("button", { name: "cancel-action" })).toBeDisabled();
    expect(props.onCancel).not.toHaveBeenCalled();
  });

  it("処理中も、Tab でダイアログの外へ出ない", async () => {
    const user = userEvent.setup();
    render(
      <>
        <ConfirmDialog {...dialogProps({ busy: true })} />
        <button type="button">outside-after</button>
      </>,
    );

    await user.tab();
    await user.tab();

    expect(screen.getByRole("alertdialog")).toContainElement(document.activeElement as HTMLElement);
  });
});

describe("ConfirmDialog: 閉じたあとのフォーカス", () => {
  function Harness({ fallbackFocusId, removeTriggerOnClose = false }: { fallbackFocusId?: string; removeTriggerOnClose?: boolean }) {
    const [open, setOpen] = useState(false);
    const [triggerVisible, setTriggerVisible] = useState(true);
    return (
      <>
        {triggerVisible && (
          <button type="button" onClick={() => setOpen(true)}>
            open-dialog
          </button>
        )}
        <button type="button" id="fallback-target">
          fallback
        </button>
        {open && (
          <ConfirmDialog
            {...dialogProps({
              fallbackFocusId,
              onCancel: () => setOpen(false),
              onConfirm: () => {
                if (removeTriggerOnClose) {
                  setTriggerVisible(false);
                }
                setOpen(false);
              },
            })}
          />
        )}
      </>
    );
  }

  it("閉じたら、開いたときに押したボタンへ、フォーカスを戻す", async () => {
    const user = userEvent.setup();
    render(<Harness />);

    await user.click(screen.getByRole("button", { name: "open-dialog" }));
    expect(screen.getByRole("alertdialog")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "cancel-action" }));

    expect(screen.queryByRole("alertdialog")).toBeNull();
    expect(screen.getByRole("button", { name: "open-dialog" })).toHaveFocus();
  });

  it("Escape で閉じたときも、押したボタンへ戻す", async () => {
    const user = userEvent.setup();
    render(<Harness />);

    await user.click(screen.getByRole("button", { name: "open-dialog" }));
    await user.keyboard("{Escape}");

    expect(screen.getByRole("button", { name: "open-dialog" })).toHaveFocus();
  });

  it("押したボタンが、閉じるときに無くなっていたら、指定の戻し先（fallbackFocusId）へ戻す", async () => {
    const user = userEvent.setup();
    render(<Harness fallbackFocusId="fallback-target" removeTriggerOnClose />);

    await user.click(screen.getByRole("button", { name: "open-dialog" }));
    await user.click(screen.getByRole("button", { name: "confirm-action" }));

    expect(screen.queryByRole("button", { name: "open-dialog" })).toBeNull();
    expect(screen.getByRole("button", { name: "fallback" })).toHaveFocus();
  });
});

describe("ConfirmDialog: 背景が inert のとき（実際のブラウザ）の、フォーカスの復帰", () => {
  // 実際のブラウザでは、画面の背景を inert にすると、(1) フォーカスのあった要素は、フォーカスを失い（document.activeElement は body になる）、
  // (2) inert の間は、フォーカスを受け取れない。jsdom は inert を実装しないため、同じ挙動を、コミットの直後（パッシブな効果より前）の
  // レイアウト効果で再現する。開発サーバーの Strict Mode は、ダイアログの効果を、実行 > 後始末 > 実行の順で 2 回走らせる。
  function InertHarness({ fallbackFocusId }: { fallbackFocusId?: string }) {
    const [open, setOpen] = useState(false);
    const triggerRef = useRef<HTMLButtonElement>(null);

    useLayoutEffect(() => {
      const trigger = triggerRef.current;
      if (!open || trigger === null) {
        return undefined;
      }
      const originalFocus = trigger.focus;
      trigger.blur();
      trigger.focus = () => undefined;
      return () => {
        trigger.focus = originalFocus;
      };
    }, [open]);

    return (
      <>
        <button type="button" ref={triggerRef} onClick={() => setOpen(true)}>
          open-dialog
        </button>
        <button type="button" id="fallback-target">
          fallback
        </button>
        {open && <ConfirmDialog {...dialogProps({ fallbackFocusId, onCancel: () => setOpen(false) })} />}
      </>
    );
  }

  it("背景が inert になって、フォーカスが外れても、閉じたら、開いたときに押したボタンへ戻す", async () => {
    const user = userEvent.setup();
    render(<InertHarness />);

    await user.click(screen.getByRole("button", { name: "open-dialog" }));
    expect(screen.getByRole("button", { name: "cancel-action" })).toHaveFocus();
    await user.click(screen.getByRole("button", { name: "cancel-action" }));

    expect(screen.queryByRole("alertdialog")).toBeNull();
    expect(screen.getByRole("button", { name: "open-dialog" })).toHaveFocus();
  });

  it("Escape で閉じたときも、押したボタンへ戻す", async () => {
    const user = userEvent.setup();
    render(<InertHarness />);

    await user.click(screen.getByRole("button", { name: "open-dialog" }));
    await user.keyboard("{Escape}");

    expect(screen.getByRole("button", { name: "open-dialog" })).toHaveFocus();
  });

  it("Strict Mode（効果を 2 回実行する）でも、押したボタンへ戻す（ダイアログ自身のボタンを、戻し先にしない）", async () => {
    const user = userEvent.setup();
    render(
      <StrictMode>
        <InertHarness fallbackFocusId="fallback-target" />
      </StrictMode>,
    );

    await user.click(screen.getByRole("button", { name: "open-dialog" }));
    expect(screen.getByRole("button", { name: "cancel-action" })).toHaveFocus();
    await user.keyboard("{Escape}");

    expect(screen.getByRole("button", { name: "open-dialog" })).toHaveFocus();
  });

  it("開いたときに、フォーカスのある要素が無ければ（body）、指定の戻し先（fallbackFocusId）へ戻す", () => {
    render(<InertHarness fallbackFocusId="fallback-target" />);

    // クリックではなく、イベントだけを送る（ボタンへ、フォーカスを移さない）
    fireEvent.click(screen.getByRole("button", { name: "open-dialog" }));
    expect(screen.getByRole("button", { name: "cancel-action" })).toHaveFocus();
    fireEvent.click(screen.getByRole("button", { name: "cancel-action" }));

    expect(screen.queryByRole("alertdialog")).toBeNull();
    expect(screen.getByRole("button", { name: "fallback" })).toHaveFocus();
  });
});

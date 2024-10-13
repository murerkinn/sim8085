import { createEffect, createSignal, onCleanup, onMount, useContext } from "solid-js";
import { EditorState, StateField, StateEffect, RangeSet, Compartment } from "@codemirror/state";
import { EditorView, GutterMarker, Decoration, keymap, gutter } from "@codemirror/view";
import { defaultKeymap, indentWithTab } from "@codemirror/commands";
import { basicSetup } from "codemirror";
import { StoreContext } from "../StoreContext";
import { Syntax8085 } from "./8085";
import debounce from 'debounce';
import './CodeMirror.css';
import { Tooltip } from "@kobalte/core/tooltip";
import { FiHelpCircle } from "solid-icons/fi";
import { store, setStore } from '../../store/store';

export function CodeMirror(props) {
  let editorRef; // Reference to the DOM element where CodeMirror will be mounted
  const [isEditorLoading, setIsEditorLoading] = createSignal(true);

  const updateBreakpoint = (line) => {
    const action = store.breakpoints.find(l => l === line) != null ? 'remove' : 'add';
    if (action === 'add') {
      setStore('breakpoints', (breakpoints) => [line].concat(breakpoints));
    } else if (action === 'remove') {
      setStore('breakpoints', (breakpoints) => breakpoints.filter(b => b !== line));
    }
  };

  const breakpointEffect = StateEffect.define({
    map: (val, mapping) => ({pos: mapping.mapPos(val.pos), on: val.on})
  })

  const breakpointState = StateField.define({
    create() { return RangeSet.empty },
    update(set, transaction) {
      set = set.map(transaction.changes)
      for (let e of transaction.effects) {
        if (e.is(breakpointEffect)) {
          if (e.value.on)
            set = set.update({add: [breakpointMarker.range(e.value.pos)]})
          else
            set = set.update({filter: from => from != e.value.pos})
        }
      }
      return set
    }
  })

  function toggleBreakpoint(view, pos) {
    let breakpoints = view.state.field(breakpointState)
    let hasBreakpoint = false
    breakpoints.between(pos, pos, () => {hasBreakpoint = true})
    view.dispatch({
      effects: breakpointEffect.of({pos, on: !hasBreakpoint})
    })
  }

  const breakpointMarker = new class extends GutterMarker {
    toDOM() { return document.createTextNode("💔") }
  };

  const breakpointGutter = [
    breakpointState,
    gutter({
      class: "cm-breakpoint-gutter",
      markers: v => v.state.field(breakpointState),
      initialSpacer: () => breakpointMarker,
      domEventHandlers: {
        mousedown(view, line) {
          toggleBreakpoint(view, line.from);
          updateBreakpoint(line.from);
          return true
        }
      }
    }),
    EditorView.baseTheme({
      ".cm-breakpoint-gutter .cm-gutterElement": {
        color: "red",
        paddingLeft: "5px",
        cursor: "default"
      }
    })
  ];

  const addLineHighlight = StateEffect.define();
  const removeLineHighlight = StateEffect.define();

  const lineHighlightField = StateField.define({
    create() {
      return Decoration.none;
    },
    update(lines, tr) {
      lines = lines.map(tr.changes);
      for (let e of tr.effects) {
        if (e.is(addLineHighlight)) {
          lines = Decoration.none;
          lines = lines.update({add: [lineHighlightMark.range(e.value)]});
        } else if (e.is(removeLineHighlight)) {
          console.log('Remove line highlight');
          lines = Decoration.none;
        }
      }
      return lines;
    },
    provide: (f) => EditorView.decorations.from(f),
  });

  const lineHighlightMark = Decoration.line({
    attributes: { class: 'cm-debug-line-highlight' },
  });

  const readOnly = new Compartment;

  let view = null;
  // Initialize the CodeMirror editor
  onMount(() => {
    const onChangeListener = EditorView.updateListener.of((update) => {
      if (update.docChanged) {
        const newDoc = update.state.doc.toString(); // Get the new document content
        setStore("code", newDoc); // Update the store with new content
        if (store.assembled.length) {
          setStore("assembled", []);
        }
        localStorage.setItem("main.asm", newDoc);
      }
    });

    const storedFile = localStorage.getItem("main.asm");

    // Create the initial state for the editor
    const startState = EditorState.create({
      doc: storedFile || store.code, // Load from store or default content
      extensions: [
        breakpointGutter,
        lineHighlightField,
        basicSetup,
        keymap.of([defaultKeymap, indentWithTab]),
        onChangeListener,
        Syntax8085(),
        readOnly.of(EditorState.readOnly.of(false))
      ],
    });

    if (storedFile) {
      setStore("code", storedFile);
    }

    // Create the editor view
    view = new EditorView({
      state: startState,
      parent: editorRef, // Mount the editor inside the editorRef div
    });
    setIsEditorLoading(false);

    // Cleanup when the component is destroyed
    onCleanup(() => {
      view.destroy(); // Destroy the editor instance
    });
  });

  createEffect(() => {
    if (!view) return;

    if (store.programState !== 'Idle') {
      view.dispatch({
        effects: readOnly.reconfigure(EditorState.readOnly.of(true))
      });
    } else {
      view.dispatch({
        effects: readOnly.reconfigure(EditorState.readOnly.of(false))
      });
    }
  });

  createEffect(() => {
    if (!view) return;

    if (!(store.programState === 'Paused' || store.programState === 'Running')) {
      view.dispatch({effects: removeLineHighlight.of()});
    }

    console.log("programCounter", store.programCounter);
    const lineNo = store.assembled.find((line) => line.currentAddress === store.programCounter)?.location.start.line;
    if (!lineNo) return;
    console.log('==== Line to Highlight ====');
    console.log(lineNo);
    const docPosition = view.state.doc.line(lineNo).from;
    console.log(`====== Program State ====== ${store.programState}`);
    if (store.programState === 'Paused' || store.programState === 'Running') {
      view.dispatch({effects: addLineHighlight.of(docPosition)});
    } else {
      view.dispatch({effects: removeLineHighlight.of(docPosition)});
    }
  });

  return (
    <div class="relative">
      <div ref={editorRef} class="editor-container border border-gray-300 dark:border-gray-600 border-l-0 border-b-0" style={{ height: "calc(100vh - 8rem - 1px)"}}>
        <div class={`${isEditorLoading() ? '' : 'hidden'} p-4 text-center`}>
          Editor is loading...
        </div>
      </div>
      <span class={`${store.programState === 'Idle' ? 'hidden' : ''} absolute text-xs text-gray-100 px-3 py-2 top-2 right-2 rounded-sm bg-red-500 dark:bg-red-700 flex items-center gap-1 opacity-80`}>
        <span>Editor is Read Only</span>
        <Tooltip>
          <Tooltip.Trigger class="tooltip__trigger">
            <span class="cursor-help text-lg"><FiHelpCircle /></span>
          </Tooltip.Trigger>
          <Tooltip.Portal>
            <Tooltip.Content class="tooltip__content">
              <Tooltip.Arrow />
              <p>Editing is not allowed while program is loaded into memory to avoid mismatch between code and loaded program. Unload the program from memory to edit again.</p>
            </Tooltip.Content>
          </Tooltip.Portal>
        </Tooltip>
      </span>
    </div>
  );
}
# Doc model

* Moving or indenting any block with an indented section below it should move/indent the whole section, not just the single block. This should happen whether moving by drag-and-drop, keyboard shortcuts, etc. This means the gesture recognizers and so one and the draggable chips etc need to be able to query the document model to know how many blocks are in the section being moved.
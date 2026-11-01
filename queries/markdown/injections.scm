; extends

; Markdown otherwise keeps compact details bodies in an opaque HTML block.
; Keep the body contiguous so HTML inside a fenced code example stays literal.
((html_block) @injection.content
  (#inkstone-details-body? @injection.content)
  (#inkstone-details-body! @injection.content)
  (#set! injection.include-children)
  (#set! injection.language "markdown"))

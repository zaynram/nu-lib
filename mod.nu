# Internal module library hosting numerous developer and personal facing modules.
const PRELUDE: path = path self ./prelude/mod.nu
export-env { source-env $PRELUDE }

return {
  {
    "okuuva/auto-save.nvim",
    cmd = "ASToggle",
    event = { "InsertLeave", "TextChanged" },
    opts = {
      enabled = true,
      trigger_events = { -- See :h auto-save-events
        immediate_save = { "BufLeave", "FocusLost" }, -- vim events that trigger an immediate save
        defer_save = { "InsertLeave", "TextChanged" }, -- vim events that trigger a deferred save (with delay)
        cancel_deferred_save = { "InsertEnter" }, -- vim events that cancel a deferred save
      },
      condition = nil,
      write_all_buffers = false, -- write all modified buffers or only the current one
      no_filetype_is_saveable = false, -- whether to save "no-filetype" files
      debounce_delay = 1000, -- save after 1000ms of inactivity
      debug = false,
    },
  },
}

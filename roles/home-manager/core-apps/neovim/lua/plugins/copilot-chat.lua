return {
  {
    "CopilotC-Nvim/CopilotChat.nvim",
    dependencies = {
      { "github/copilot.vim" }, -- Ensure you have copilot.vim already installed
      { "nvim-lua/plenary.nvim" },
    },
    opts = {
      window = {
        layout = "float", -- 'vertical', 'horizontal', 'float', 'replace'
        title = "Copilot Chat",
        border = "single", -- 'none', single', 'double', 'rounded', 'solid', 'shadow'
        width = 0.8, -- fractional width of parent
        height = 0.7, -- fractional height of parent
      },
      -- Replace with your preferred model (gpt-4o, gpt-4, etc.)
      model = "claude-sonnet-4",
      -- Additional configuration options
      show_help = true,
      prompts = {
        Explain = {
          prompt = "Explain how this code works in detail.",
        },
        Review = {
          prompt = "Review the code and suggest improvements.",
        },
        Fix = {
          prompt = "Fix issues in this code and explain what was wrong.",
        },
        Optimize = {
          prompt = "Optimize this code for better performance.",
        },
        Tests = {
          prompt = "Write tests for this code.",
        },
      },
    },
    cmd = {
      "CopilotChat",
      "CopilotChatOpen", 
      "CopilotChatToggle",
      "CopilotChatExplain", 
      "CopilotChatReview", 
      "CopilotChatFix", 
      "CopilotChatOptimize", 
      "CopilotChatTests"
    },
    keys = {
      { "<leader>cc", "<cmd>CopilotChatToggle<cr>", desc = "Toggle Copilot Chat" },
      { "<leader>ce", "<cmd>CopilotChatExplain<cr>", desc = "Explain Code with Copilot" },
      { "<leader>cr", "<cmd>CopilotChatReview<cr>", desc = "Review Code with Copilot" },
      { "<leader>cf", "<cmd>CopilotChatFix<cr>", desc = "Fix Code with Copilot" },
      { "<leader>co", "<cmd>CopilotChatOptimize<cr>", desc = "Optimize Code with Copilot" },
      { "<leader>ct", "<cmd>CopilotChatTests<cr>", desc = "Generate Tests with Copilot" },
    },
  },
}

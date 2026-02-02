defmodule Manfrod.Telegram.Formatter do
  @moduledoc """
  Converts markdown to Telegram-compatible HTML.

  Telegram supports a limited subset of HTML:
  - `<b>`, `<i>`, `<u>`, `<s>` for text formatting
  - `<code>` for inline code
  - `<pre><code class="language-X">` for code blocks
  - `<a href="...">` for links
  - `<blockquote>` for quotes

  Unsupported elements are converted:
  - Headers -> bold text
  - Lists -> indented bullet points (plain text)
  - Tables -> plain text
  - Images -> links
  - Horizontal rules -> newline
  """

  @max_tool_args_length 100

  @doc """
  Convert markdown text to Telegram HTML.

  Returns HTML string suitable for sending with `parse_mode: "HTML"`.
  """
  def to_telegram_html(markdown) when is_binary(markdown) do
    case Earmark.as_ast(markdown, breaks: true) do
      {:ok, ast, _} ->
        ast
        |> convert_ast(0)
        |> IO.iodata_to_binary()
        |> String.trim()

      {:error, _, _} ->
        # Fallback: escape and return as-is
        escape_html(markdown)
    end
  end

  @doc """
  Format a tool call for display.

  Returns formatted string like: `<code>tool_name({"arg": "value", ...})</code>`
  """
  def format_tool_call(tool_name, args_json) when is_binary(tool_name) do
    truncated_args = truncate_args(args_json)
    "<code>#{escape_html(tool_name)}(#{escape_html(truncated_args)})</code>"
  end

  def format_tool_call(tool_name, nil), do: "<code>#{escape_html(tool_name)}()</code>"

  # --- AST Conversion ---

  defp convert_ast(nodes, depth) when is_list(nodes) do
    Enum.map(nodes, &convert_node(&1, depth))
  end

  # Plain text - escape HTML entities
  defp convert_node(text, _depth) when is_binary(text) do
    escape_html(text)
  end

  # Paragraph - render contents, add newlines
  defp convert_node({"p", _attrs, children, _meta}, depth) do
    [convert_ast(children, depth), "\n\n"]
  end

  # Bold/Strong
  defp convert_node({"strong", _attrs, children, _meta}, depth) do
    ["<b>", convert_ast(children, depth), "</b>"]
  end

  # Italic/Emphasis
  defp convert_node({"em", _attrs, children, _meta}, depth) do
    ["<i>", convert_ast(children, depth), "</i>"]
  end

  # Strikethrough
  defp convert_node({"del", _attrs, children, _meta}, depth) do
    ["<s>", convert_ast(children, depth), "</s>"]
  end

  # Inline code
  defp convert_node({"code", attrs, children, _meta}, depth) do
    # Check if it's inside a <pre> (has language class) - handled by pre
    case List.keyfind(attrs, "class", 0) do
      {"class", "inline"} ->
        ["<code>", convert_ast(children, depth), "</code>"]

      _ ->
        # Standalone code or code block content
        ["<code>", convert_ast(children, depth), "</code>"]
    end
  end

  # Pre-formatted code block
  defp convert_node({"pre", _attrs, children, _meta}, depth) do
    # Children is typically [{"code", attrs, content, meta}]
    case children do
      [{"code", attrs, code_content, _}] ->
        lang_class = extract_language_class(attrs)
        code_text = extract_text(code_content)

        if lang_class do
          ["<pre><code class=\"", lang_class, "\">", escape_html(code_text), "</code></pre>\n\n"]
        else
          ["<pre>", escape_html(code_text), "</pre>\n\n"]
        end

      _ ->
        ["<pre>", convert_ast(children, depth), "</pre>\n\n"]
    end
  end

  # Links
  defp convert_node({"a", attrs, children, _meta}, depth) do
    href = List.keyfind(attrs, "href", 0)

    case href do
      {"href", url} ->
        ["<a href=\"", escape_html(url), "\">", convert_ast(children, depth), "</a>"]

      nil ->
        convert_ast(children, depth)
    end
  end

  # Blockquote
  defp convert_node({"blockquote", _attrs, children, _meta}, depth) do
    ["<blockquote>", convert_ast(children, depth), "</blockquote>\n"]
  end

  # Headers -> Bold text with newline
  defp convert_node({tag, _attrs, children, _meta}, depth)
       when tag in ~w(h1 h2 h3 h4 h5 h6) do
    ["<b>", convert_ast(children, depth), "</b>\n\n"]
  end

  # Unordered list
  defp convert_node({"ul", _attrs, children, _meta}, depth) do
    items = convert_list_items(children, depth, :unordered)
    [items, "\n"]
  end

  # Ordered list
  defp convert_node({"ol", attrs, children, _meta}, depth) do
    start =
      case List.keyfind(attrs, "start", 0) do
        {"start", n} -> String.to_integer(n)
        nil -> 1
      end

    items = convert_list_items(children, depth, {:ordered, start})
    [items, "\n"]
  end

  # List item - handled by convert_list_items
  defp convert_node({"li", _attrs, children, _meta}, depth) do
    convert_ast(children, depth)
  end

  # Horizontal rule -> newline
  defp convert_node({"hr", _attrs, _children, _meta}, _depth) do
    "\n"
  end

  # Image -> link or alt text
  defp convert_node({"img", attrs, _children, _meta}, _depth) do
    src = get_attr(attrs, "src", "")
    alt = get_attr(attrs, "alt", "image")

    if src != "" do
      ["<a href=\"", escape_html(src), "\">", escape_html(alt), "</a>"]
    else
      escape_html(alt)
    end
  end

  # Line break
  defp convert_node({"br", _attrs, _children, _meta}, _depth) do
    "\n"
  end

  # Table -> plain text representation
  defp convert_node({"table", _attrs, children, _meta}, depth) do
    [convert_table(children, depth), "\n"]
  end

  # Catch-all for other elements - just render children
  defp convert_node({_tag, _attrs, children, _meta}, depth) do
    convert_ast(children, depth)
  end

  # --- List Helpers ---

  defp convert_list_items(items, depth, list_type) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {item, index} ->
      convert_list_item(item, depth, list_type, index)
    end)
  end

  defp convert_list_item({"li", _attrs, children, _meta}, depth, list_type, index) do
    indent = String.duplicate("  ", depth)

    bullet =
      case list_type do
        :unordered -> "- "
        {:ordered, start} -> "#{start + index}. "
      end

    # Check if children contain nested lists
    {text_children, nested_lists} =
      Enum.split_with(children, fn
        {"ul", _, _, _} -> false
        {"ol", _, _, _} -> false
        _ -> true
      end)

    text_content =
      text_children
      |> convert_ast(depth)
      |> IO.iodata_to_binary()
      |> String.trim()

    nested_content =
      nested_lists
      |> Enum.map(&convert_node(&1, depth + 1))

    [indent, bullet, text_content, "\n", nested_content]
  end

  defp convert_list_item(other, depth, _list_type, _index) do
    convert_node(other, depth)
  end

  # --- Table Helpers ---

  defp convert_table(children, depth) do
    children
    |> Enum.flat_map(fn
      {"thead", _, rows, _} -> rows
      {"tbody", _, rows, _} -> rows
      {"tr", _, _, _} = row -> [row]
      _ -> []
    end)
    |> Enum.map(&convert_table_row(&1, depth))
  end

  defp convert_table_row({"tr", _attrs, cells, _meta}, depth) do
    cell_texts =
      cells
      |> Enum.map(fn
        {cell_tag, _, content, _} when cell_tag in ~w(td th) ->
          content
          |> convert_ast(depth)
          |> IO.iodata_to_binary()
          |> String.trim()

        other ->
          other
          |> convert_node(depth)
          |> IO.iodata_to_binary()
          |> String.trim()
      end)
      |> Enum.join(" | ")

    [cell_texts, "\n"]
  end

  defp convert_table_row(other, depth), do: convert_node(other, depth)

  # --- Helpers ---

  defp extract_language_class(attrs) do
    case List.keyfind(attrs, "class", 0) do
      {"class", class} ->
        # Extract language-X from class
        case Regex.run(~r/language-(\w+)/, class) do
          [_, lang] -> "language-#{lang}"
          nil -> nil
        end

      nil ->
        nil
    end
  end

  defp extract_text(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(&extract_text/1)
    |> Enum.join()
  end

  defp extract_text(text) when is_binary(text), do: text

  defp extract_text({_tag, _attrs, children, _meta}) do
    extract_text(children)
  end

  defp get_attr(attrs, key, default) do
    case List.keyfind(attrs, key, 0) do
      {^key, value} -> value
      nil -> default
    end
  end

  @doc """
  Escape HTML entities in text.
  """
  def escape_html(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  def escape_html(other), do: to_string(other)

  defp truncate_args(nil), do: ""
  defp truncate_args(""), do: ""

  defp truncate_args(args_json) when is_binary(args_json) do
    if String.length(args_json) > @max_tool_args_length do
      truncated = String.slice(args_json, 0, @max_tool_args_length)
      # Try to truncate at a reasonable point (after a comma or colon)
      truncated =
        case Regex.run(~r/^(.+[,:])\s*[^,]*$/, truncated) do
          [_, better] -> better
          nil -> truncated
        end

      "#{truncated} ..."
    else
      args_json
    end
  end
end

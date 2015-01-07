defmodule Eml.Language.Html.Reader do

  # API

  @spec read(binary, atom) :: Eml.element | Eml.error
  def read(html, BitString) do
    res = case parse(html, { :blank, [] }, [], :blank) do
            { :error, state } ->
              { :error, state }
            tokens ->
              compile(tokens)
          end
    case res do
      { :error, state } ->
        { :error, state }
      { markup, [] } ->
        markup
      { markup, rest }->
        { :error, [compiled: markup, rest: rest] }
    end
  end

  # Html parsing

  # Skip comments
  defp parse(<<"<!--", rest::binary>>, buf, acc, _) do
    parse(rest, buf, acc, :comment)
  end
  defp parse(<<"-->", rest::binary>>, buf, acc, :comment) do
    { state, _ } = buf
    parse(rest, buf, acc, state)
  end
  defp parse(<<_, rest::binary>>, buf, acc, :comment) do
    parse(rest, buf, acc, :comment)
  end

  # Skip doctype
  defp parse(<<"<!DOCTYPE", rest::binary>>, buf, acc, :blank) do
    parse(rest, buf, acc, :doctype)
  end
  defp parse(<<"<!doctype", rest::binary>>, buf, acc, :blank) do
    parse(rest, buf, acc, :doctype)
  end
  defp parse(<<">", rest::binary>>, buf, acc, :doctype) do
    parse(rest, buf, acc, :blank)
  end
  defp parse(<<_, rest::binary>>, buf, acc, :doctype) do
    parse(rest, buf, acc, :doctype)
  end

  # Parameters
  defp parse(<<"#param{", rest::binary>>, buf, acc, state) do
    case state do
      s when s in [:content, :blank, :start_close, :end_close, :close] ->
        next(rest, buf, "", acc, :param_content)
      s when s in [:attr_single_open, :attr_double_open, :attr_value] ->
        next(rest, buf, "", acc, :param_attr)
      _ ->
        error("#param", rest, buf, acc, state)
    end
  end
  defp parse(<<"}", rest::binary>>, buf, acc, :param_content) do
    next(rest, buf, "", acc, :content)
  end
  defp parse(<<"}", rest::binary>>, buf, acc, :param_attr) do
    next(rest, buf, "", acc, :attr_value)
  end

  # CDATA
  defp parse(<<"<![CDATA[", rest::binary>>, buf, acc, state)
  when state in [:content, :blank, :start_close, :end_close, :close] do
    next(rest, buf, "", acc, :cdata)
  end
  defp parse(<<"]]>", rest::binary>>, buf, acc, :cdata) do
    next(rest, buf, "", acc, :content)
  end
  defp parse(<<char, rest::binary>>, buf, acc, :cdata) do
    consume(char, rest, buf, acc, :cdata)
  end
  # Makes it possible for elements to treat its contents as if cdata
  defp parse(chars, buf, acc, { :cdata, end_tag } = state) do
    end_token = "</" <> end_tag <> ">"
    n = byte_size(end_token)
    case chars do
      <<^end_token::binary-size(n), rest::binary>> ->
        acc = change(buf, acc, :cdata)
        acc = change({ :open, "<" }, acc)
        acc = change({ :slash, "/" }, acc)
        acc = change({ :end_tag, end_tag }, acc)
        parse(rest, { :end_close, ">" }, acc, :end_close)
      <<char, rest::binary>> ->
        consume(char, rest, buf, acc, state)
      "" ->
        :lists.reverse([buf | acc])
    end
  end

  # Entities
  defp parse(<<"&", rest::binary>>, buf, acc, state) do
    { entity, rest } = get_entity(rest)
    consume(entity, rest, buf, acc, state)
  end

  # Attribute quotes
  defp parse(<<"'", rest::binary>>, buf, acc, :attr_sep) do
    next(rest, buf, "'", acc, :attr_single_open)
  end
  defp parse(<<"\"", rest::binary>>, buf, acc, :attr_sep) do
    next(rest, buf, "\"", acc, :attr_double_open)
  end
  defp parse(<<char, rest::binary>>, buf, acc, :attr_value) when char in [?\", ?\'] do
    case { char, previous_state(acc, [:attr_value]) } do
      t when t in [{ ?\', :attr_single_open }, { ?\", :attr_double_open }] ->
        next(rest, buf, char, acc, :attr_close)
      _else ->
        consume(char, rest, buf, acc, :attr_value)
    end
  end
  defp parse(<<char, rest::binary>>, buf, acc, state)
  when { char, state } in [{ ?\', :attr_single_open }, { ?\", :attr_double_open }] do
    next(rest, buf, char, acc, :attr_close)
  end

  # Attributes values accept any character
  defp parse(<<char, rest::binary>>, buf, acc, state)
  when state in [:attr_single_open, :attr_double_open] do
    next(rest, buf, char, acc, :attr_value)
  end
  defp parse(<<char, rest::binary>>, buf, acc, :attr_value) do
    consume(char, rest, buf, acc, :attr_value)
  end

  # Attribute field/value seperator
  defp parse(<<"=", rest::binary>>, buf, acc, :attr_field) do
    next(rest, buf, "=", acc, :attr_sep)
  end

  # Allow boolean attributes, ie. attributes with only a field name
  defp parse(<<char, rest::binary>>, buf, acc, :attr_field)
  when char in [?\>, ?\s, ?\n, ?\r, ?\t] do
    next(<<char, rest::binary>>, buf, "\"", acc, :attr_close)
  end

  # Whitespace handling
  defp parse(<<char, rest::binary>>, buf, acc, state)
  when char in [?\s, ?\n, ?\r, ?\t] do
    case state do
      :start_tag ->
        next(rest, buf, "", acc, :start_tag_close)
      s when s in [:close, :start_close, :end_close] ->
        if char in [?\n, ?\r] do
          next(rest, buf, "", acc, :content)
        else
          next(rest, buf, char, acc, :content)
        end
      :content ->
        consume(char, rest, buf, acc, state)
      _ ->
        parse(rest, buf, acc, state)
    end
  end

  # Open tag
  defp parse(<<"<", rest::binary>>, buf, acc, state) do
    case state do
      s when s in [:blank, :start_close, :end_close, :close, :content] ->
        next(rest, buf, "<", acc, :open)
      _ ->
        error("<", rest, buf, acc, state)
    end
  end

  # Close tag
  defp parse(<<">", rest::binary>>, buf, acc, state) do
    case state do
      s when s in [:attr_close, :start_tag] ->
        # The html parser doesn't support arbitrary markup without proper closing.
        # However, it does makes exceptions for tags specified in is_void_element?/1
        # and assume they never have children.
        tag = get_last_tag(acc, buf)
        if is_void_element?(tag) do
          next(rest, buf, ">", acc, :close)
        else
          # check if the content of the element should be interpreted as cdata
          case element_type([buf | acc]) do
            :content ->
              next(rest, buf, ">", acc, :start_close)
            { :cdata, tag } ->
              acc = change(buf, acc)
              next(rest, { :start_close, ">" }, "", acc, { :cdata, tag })
          end
        end
      :slash ->
        next(rest, buf, ">", acc, :close)
      :end_tag ->
        next(rest, buf, ">", acc, :end_close)
      _ ->
        def_parse(<<">", rest::binary>>, buf, acc, state)
    end
  end

  # Slash
  defp parse(<<"/", rest::binary>>, buf, acc, state)
  when state in [:open, :attr_field, :attr_close, :start_tag, :start_tag_close] do
    next(rest, buf, "/", acc, :slash)
  end

  defp parse("", buf, acc, _) do
    :lists.reverse([buf | acc])
  end

  # Default parsing
  defp parse(chars, buf, acc, state), do: def_parse(chars, buf, acc, state)

  # Either start or consume content, tag or parameter.
  defp def_parse(<<char, rest::binary>>, buf, acc, state) do
    case state do
      s when s in [:start_tag, :end_tag, :attr_field, :content, :param_content, :param_attr] ->
        consume(char, rest, buf, acc, state)
      s when s in [:blank, :start_close, :end_close, :close] ->
        next(rest, buf, char, acc, :content)
      s when s in [:attr_close, :start_tag_close] ->
        next(rest, buf, char, acc, :attr_field)
      :open ->
        next(rest, buf, char, acc, :start_tag)
      :slash ->
        next(rest, buf, char, acc, :end_tag)
      _ ->
        error(char, rest, buf, acc, state)
    end
  end

  # Stops tokenizing and dumps all info in a tuple
  defp error(char, rest, buf, acc, state) do
    char = if is_integer(char), do: <<char>>, else: char
    state = [state: state,
             char: char,
             buf: buf,
             last_token: List.first(acc),
             next_char: String.first(rest)]
    { :error, state}
  end

  # Consumes character and put it in the buffer
  defp consume(char, rest, { type, buf }, acc, state) do
    char = if is_integer(char), do: <<char>>, else: char
    parse(rest, { type, buf <> char }, acc, state)
  end

  # Add the old buffer to the accumulator and start a new buffer
  defp next(rest, old_buf, new_buf, acc, new_state) do
    acc = change(old_buf, acc)
    new_buf = if is_integer(new_buf), do: <<new_buf>>, else: new_buf
    parse(rest, { new_state, new_buf }, acc, new_state)
  end

  # Add buffer to the accumulator if its content is not empty.
  defp change({ type, buf }, acc, type_modifier \\ nil) do
    type = if is_nil(type_modifier), do: type, else: type_modifier
    token = { type, buf }
    if empty?(token) do
      acc
    else
      [token | acc]
    end
  end

  # Checks for empty content
  defp empty?({ :blank, _ }), do: true
  defp empty?({ :content, content }) do
    String.strip(content) === ""
  end
  defp empty?(_), do: false

  # Checks if last parsed tag is a tag that should always close.
  defp get_last_tag(tokens, { type, buf }) do
    get_last_tag([{ type, buf } | tokens])
  end

  defp get_last_tag([{ :start_tag, tag } | _]), do: tag
  defp get_last_tag([_ | ts]), do: get_last_tag(ts)
  defp get_last_tag([]), do: nil

  defp is_void_element?(tag) do
    tag in ["area", "base", "br", "col", "embed", "hr", "img", "input", "keygen", "link", "meta", "param", "source", "track", "wbr"]
  end

  defp previous_state([{ state, _ } | rest], skip_states) do
    if state in skip_states do
      previous_state(rest, skip_states)
    else
      state
    end
  end
  defp previous_state([], _), do: :blank

  # CDATA element helper

  @cdata_elements ["script", "style"]

  defp element_type(acc) do
    case get_last_tag(acc) do
      nil ->
        :content
      tag ->
        if tag in @cdata_elements do
          { :cdata, tag }
        else
          :content
        end
    end
  end

  # Entity helpers

  @entity_map %{"amp"    => "&",
                "lt"     => "<",
                "gt"     => ">",
                "quot"   => "\"",
                "hellip" => "…"}

  defp get_entity(chars) do
    entities = Map.keys(@entity_map)
    max_length = Enum.reduce(entities, 0, fn e, acc ->
      length = String.length(e)
      if length > acc, do: length, else: acc
    end)
    case get_entity(chars, "", entities, max_length) do
      { e, rest } -> { @entity_map[e], rest }
      nil         -> { "&", chars }
    end
  end

  defp get_entity(<<";", rest::binary>>, acc, entities, _) do
    if acc in entities do
      { acc, rest }
    end
  end
  defp get_entity(<<char, rest::binary>>, acc, entities, max_length) do
    acc = acc <> <<char>>
    unless String.length(acc) > max_length do
      get_entity(rest, acc, entities, max_length)
    end
  end
  defp get_entity("", _, _, _), do: nil

  # Compile the genrated tokens

  defp compile(tokens) do
    compile_content(tokens, [])
  end

  defp compile_content([{ type, token } | ts], acc) do
    case precompile(type, token) do
      :skip ->
        compile_content(ts, acc)
      { :tag, tag } ->
        { markup, tokens } = compile_markup(ts, [tag: tag, attrs: [], content: []])
        compile_content(tokens, [markup | acc])
      { :content, content } ->
        compile_content(ts, [content | acc])
      { :cdata, content } ->
        # tag cdata in order to skip whitespace trimming
        compile_content(ts, [{ :cdata, content } | acc])
      :end_el ->
        { :lists.reverse(acc), ts }
    end
  end
  defp compile_content([], acc) do
    { :lists.reverse(acc), [] }
  end

  defp compile_markup([{ type, token } | ts], acc) do
    case precompile(type, token) do
      :skip ->
        compile_markup(ts, acc)
      { :attr_field, field } ->
        attrs = [{ field, "" } | acc[:attrs]]
        compile_markup(ts, Keyword.put(acc, :attrs, attrs))
      { :attr_value, value } ->
        [{ field, current } | rest] = acc[:attrs]
        attrs = if is_binary(current) && is_binary(value) do
                  [{ field, current <> value } | rest]
                else
                  [{ field, Eml.Markup.ensure_list(current) ++ [value] } | rest]
                end
        compile_markup(ts, Keyword.put(acc, :attrs, attrs))
      :start_content ->
        { content, tokens } = compile_content(ts, [])
        { make_markup(Keyword.put(acc, :content, content)), tokens }
      :end_el ->
        { make_markup(acc), ts }
    end
  end
  defp compile_markup([], acc) do
    { make_markup(acc), [] }
  end

  defp make_markup(acc) do
    attrs = acc[:attrs]
    if attrs[:class] do
      attrs = Keyword.update!(attrs, :class, &class_value/1)
    end
    Eml.Markup.new(acc[:tag], attrs, maybe_trim_whitespace(acc[:content], acc[:tag]))
  end

  defp precompile(:blank, _),            do: :skip
  defp precompile(:open, _),             do: :skip
  defp precompile(:slash, _),            do: :skip
  defp precompile(:attr_single_open, _), do: :skip
  defp precompile(:attr_double_open, _), do: :skip
  defp precompile(:attr_close, _),       do: :skip
  defp precompile(:attr_sep, _),         do: :skip
  defp precompile(:end_tag, _),          do: :skip
  defp precompile(:start_tag_close, _),  do: :skip

  defp precompile(:attr_field, token) do
    { :attr_field, String.to_atom(token) }
  end

  defp precompile(:attr_value, token), do: { :attr_value, token }
  defp precompile(:start_tag, token), do: { :tag, String.to_atom(token) }
  defp precompile(:start_close, _), do: :start_content
  defp precompile(:content, token), do: { :content, token }
  defp precompile(:end_close, _), do: :end_el
  defp precompile(:close, _), do: :end_el

  defp precompile(:cdata, token), do: { :cdata, token }

  defp precompile(:param_content, id), do: { :content, String.to_atom(id) }
  defp precompile(:param_attr, id), do: { :attr_value, String.to_atom(id) }

  defp maybe_trim_whitespace(content, tag)
  when tag in [:textarea, :pre], do: content
  defp maybe_trim_whitespace(content, _) do
    case content do
      [only] ->
        [trim_whitespace(only, :only)]
      [] ->
        []
      [first | rest] ->
        first = trim_whitespace(first, :first)
        [first | trim_whitespace_loop(rest, [])]
    end
  end

  defp trim_whitespace_loop([last], acc) do
    last = trim_whitespace(last, :last)
    :lists.reverse([last | acc])
  end
  defp trim_whitespace_loop([h | t], acc) do
    trim_whitespace_loop(t, [trim_whitespace(h, :other) | acc])
  end

  defp trim_whitespace(content, position) do
    trim_whitespace(content, "", false, position)
  end

  defp trim_whitespace(<<c, rest::binary>>, acc, in_whitespace?, pos) do
    if c in [?\s, ?\n, ?\r, ?\t] do
      if in_whitespace? do
        trim_whitespace(rest, acc, true, pos)
      else
        trim_whitespace(rest, acc <> " ", true, pos)
      end
    else
      trim_whitespace(rest, acc <> <<c>>, false, pos)
    end
  end
  defp trim_whitespace("", acc, _, pos) do
    case pos do
      :first -> String.lstrip(acc)
      :last  -> String.rstrip(acc)
      :only  -> String.strip(acc)
      :other -> acc
    end
  end
  defp trim_whitespace({ :cdata, noop }, _, _, _), do: noop
  defp trim_whitespace(noop, _, _, _), do: noop

  defp class_value(nil), do: nil
  defp class_value(value) do
    case String.split(value, " ") do
      [class] -> class
      classes -> classes
    end
  end
end
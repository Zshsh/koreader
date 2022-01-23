local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local OverlapGroup = require("ui/widget/overlapgroup")
local RenderText = require("ui/rendertext")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Input = Device.input
local Screen = Device.screen
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

-- BookMapRow (reused by PageBrowserWidget)
local BookMapRow = InputContainer:new{
    width = nil,
    height = nil,
    pages_frame_border = Size.border.default,
    toc_span_border = Size.border.thin,
    -- pages_frame_border = 10, -- for debugging positionning
    -- toc_span_border = 5, -- for debugging positionning
    toc_items = nil, -- Arrays[levels] of arrays[items at this level to show as spans]
    -- Many other options not described here, see BookMapWidget:update()
    -- for the complete list.

    _mirroredUI = BD.mirroredUILayout(),
}

function BookMapRow:getPageX(page, right_edge)
    if right_edge then
        if (not self._mirroredUI and page == self.end_page) or
               (self._mirroredUI and page == self.start_page) then
            return self.pages_frame_inner_width
        else
            if self._mirroredUI then
                return self:getPageX(page-1)
            else
                return self:getPageX(page+1)
            end
        end
    end
    local slot_idx
    if self._mirroredUI then
        slot_idx = self.end_page - page
    else
        slot_idx = page - self.start_page
    end
    local x = slot_idx * self.page_slot_width
    x = x + math.floor(self.page_slot_extra * slot_idx / self.nb_page_slots)
    return x
end

function BookMapRow:getPageAtX(x)
    x = x - self.pages_frame_offset_x
    if x < 0 or x >= self.pages_frame_inner_width then
        return
    end
    -- Reverse of the computation in :getPageX():
    local slot_idx = math.floor(x / (self.page_slot_width + self.page_slot_extra / self.nb_page_slots))
    if self._mirroredUI then
        return self.end_page - slot_idx
    else
        return self.start_page + slot_idx
    end
end

-- Helper function to be used before instantiating a BookMapRow instance,
-- to obtain the left_spacing equivalent to not showing nb_pages at start
-- of a row of pages_per_row items in a width of row_width
function BookMapRow:getLeftSpacingForNumberOfPageSlots(nb_pages, pages_per_row, row_width)
    -- Bits of the computation done in :init()
    local pages_frame_inner_width = row_width - 2*self.pages_frame_border
    local page_slot_width = math.floor(pages_frame_inner_width / pages_per_row)
    local page_slot_extra = pages_frame_inner_width - page_slot_width * pages_per_row
    -- Bits of the computation done in :getPageX()
    local x = nb_pages * page_slot_width
    x = x + math.floor(page_slot_extra * nb_pages / pages_per_row)
    return x - self.pages_frame_border
end

function BookMapRow:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }

    -- Keep one span_height under baseline (frame bottom border) for indicators (current page, bookmarks)
    self.pages_frame_height = self.height - self.span_height

    self.pages_frame_offset_x = self.left_spacing + self.pages_frame_border
    self.pages_frame_width = self.width - self.left_spacing
    self.pages_frame_inner_width = self.pages_frame_width - 2*self.pages_frame_border
    self.page_slot_width = math.floor(self.pages_frame_inner_width / self.pages_per_row)
    self.page_slot_extra = self.pages_frame_inner_width - self.page_slot_width * self.pages_per_row -- will be distributed

    -- Update the widths if this row contains fewer pages
    self.nb_page_slots = self.end_page - self.start_page + 1
    if self.nb_page_slots ~= self.pages_per_row then
        self.page_slot_extra = math.floor(self.page_slot_extra * self.nb_page_slots / self.pages_per_row)
        self.pages_frame_inner_width = self.page_slot_width * self.nb_page_slots + self.page_slot_extra
        self.pages_frame_width = self.pages_frame_inner_width + 2*self.pages_frame_border
    end

    if self._mirroredUI then
        self.pages_frame_offset_x = self.width - self.pages_frame_width - self.left_spacing + self.pages_frame_border
    end

    -- We draw a frame container with borders for the book content, with
    -- some space on the left for the start page number, and some space
    -- below the bottom border as spacing before the next row (spacing
    -- that we can use to show current position and hanging bookmarks
    -- and highlights symbols)
    self.pages_frame = OverlapGroup:new{
        dimen = Geom:new{
            w = self.pages_frame_width,
            h = self.pages_frame_height,
        },
        allow_mirroring = false, -- we handle mirroring ourselves below
        FrameContainer:new{
            overlap_align = self._mirroredUI and "right" or "left",
            margin = 0,
            padding = 0,
            bordersize = self.pages_frame_border,
            -- color = Blitbuffer.COLOR_GRAY, -- for debugging positionning
            Widget:new{ -- empty widget to give dimensions around which to draw borders
                dimen = Geom:new{
                    w = self.pages_frame_inner_width,
                    h = self.pages_frame_height - 2*self.pages_frame_border,
                }
            }
        },
    }

    -- We won't add this margin to the FrameContainer: to be able
    -- to tweak it on some sides, we'll just tweak its overlap
    -- offsets and width to ensure the margins
    local tspan_margin = Size.margin.tiny
    local tspan_padding_h = Size.padding.tiny
    local tspan_height = self.span_height - 2 * (tspan_margin + self.toc_span_border)
    if self.toc_items then
        for lvl, items in pairs(self.toc_items) do
            local offset_y = self.pages_frame_border + self.span_height * (lvl - 1) + tspan_margin
            local prev_p_start, same_p_start_offset_dx
            for __, item in ipairs(items) do
                local text = item.title
                local p_start, p_end = item.p_start, item.p_end
                local started_before, continues_after = item.started_before, item.continues_after
                if self._mirroredUI then
                    -- Just flip these (beware below, we need to use item.p_start to get
                    -- the real start page to account in prev_p_start)
                    p_start, p_end = p_end, p_start
                    started_before, continues_after = continues_after, started_before
                end
                local offset_x = self:getPageX(p_start)
                local width = self:getPageX(p_end, true) - offset_x
                offset_x = offset_x + self.pages_frame_border
                if prev_p_start == item.p_start then
                    -- Multiple TOC items starting on the same page slot:
                    -- shift and shorten 2nd++ ones so we see a bit of
                    -- the previous overwritten span and we can know this
                    -- page slot contains multiple chapters
                    if width > same_p_start_offset_dx then
                        if not self._mirroredUI then
                            offset_x = offset_x + same_p_start_offset_dx
                        end
                        width = width - same_p_start_offset_dx
                        same_p_start_offset_dx = same_p_start_offset_dx + self.toc_span_border * 2
                    end
                else
                    prev_p_start = item.p_start
                    same_p_start_offset_dx = self.toc_span_border * 2
                end
                if started_before then
                    -- No left margin, have span border overlap with outer border
                    offset_x = offset_x - self.toc_span_border
                    width = width + self.toc_span_border
                else
                    -- Add some left margin
                    offset_x = offset_x + tspan_margin
                    width = width - tspan_margin
                end
                if continues_after then
                    -- No right margin, have span border overlap with outer border
                    width = width + self.toc_span_border
                else
                    -- Add some right margin
                    width = width - tspan_margin
                end
                local text_max_width = width - 2 * (self.toc_span_border + tspan_padding_h)
                local text_widget = nil
                if text_max_width > 0 then
                    text_widget = TextWidget:new{
                        text = BD.auto(text),
                        max_width = text_max_width,
                        face = self.font_face,
                        padding = 0,
                    }
                    if text_widget:getWidth() > text_max_width then
                        -- May happen with very small max_width when smaller
                        -- than the truncation ellipsis
                        text_widget:free()
                        text_widget = nil
                    end
                end
                local span_w = FrameContainer:new{
                    overlap_offset = {offset_x, offset_y},
                    margin = 0,
                    padding = 0,
                    bordersize = self.toc_span_border,
                    background = Blitbuffer.COLOR_WHITE,
                    CenterContainer:new{
                        dimen = Geom:new{
                            w = width - 2 * self.toc_span_border,
                            h = tspan_height,
                        },
                        text_widget or VerticalSpan:new{ width = 0 },
                    }
                }
                table.insert(self.pages_frame, span_w)
            end
        end
    end

    -- For page numbers:
    self.smaller_font_face = Font:getFace(self.font_face.orig_font, self.font_face.orig_size - 4)
    -- For current page triangle
    self.larger_font_face = Font:getFace(self.font_face.orig_font, self.font_face.orig_size + 6)

    self.hgroup = HorizontalGroup:new{
        align = "top",
    }

    if self.left_spacing > 0 then
        local spacing = Size.padding.small
        table.insert(self.hgroup, TextBoxWidget:new{
            text = self.start_page_text,
            width = self.left_spacing - spacing,
            face = self.smaller_font_face,
            line_height = 0, -- no additional line height
            alignment = self._mirroredUI and "left" or "right",
            alignment_strict = true,
        })
        table.insert(self.hgroup, HorizontalSpan:new{ width = spacing })
    end
    table.insert(self.hgroup, self.pages_frame)

    -- Get hidden flows rectangle ready to be painted gray first as background
    self.background_fillers = {}
    if self.hidden_flows then
        for _, flow_edges in ipairs(self.hidden_flows) do
            local f_start, f_end = flow_edges[1], flow_edges[2]
            if f_start <= self.end_page and f_end >= self.start_page then
                local r_start = math.max(f_start, self.start_page)
                local r_end = math.min(f_end, self.end_page)
                local x, w
                if self._mirroredUI then
                    x = self:getPageX(r_end)
                    w = self:getPageX(r_start, true) - x
                else
                    x = self:getPageX(r_start)
                    w = self:getPageX(r_end, true) - x
                end
                table.insert(self.background_fillers, {
                    x = x, y = 0,
                    w = w, h = self.pages_frame_height,
                    color = Blitbuffer.COLOR_LIGHT_GRAY,
                })
            end
        end
    end

    self[1] = LeftContainer:new{ -- needed only for auto UI mirroring
        dimen = Geom:new{
            w = self.dimen.w,
            h = self.hgroup:getSize().h,
        },
        self.hgroup,
    }

    -- Get read pages markers and other indicators ready to be drawn
    self.pages_markers = {}
    self.indicators = {}
    self.bottom_texts = {}
    local prev_page_was_read = true -- avoid one at start of row
    local unread_marker_h = math.ceil(self.span_height * 0.05)
    local read_min_h = math.max(math.ceil(self.span_height * 0.1), unread_marker_h+Size.line.thick)
    if self.page_slot_width >= 5 * unread_marker_h then
        -- If page slots are large enough, we can make unread markers a bit taller (so they
        -- are noticable and won't be confused with read page slots)
        unread_marker_h = unread_marker_h * 2
    end
    for page = self.start_page, self.end_page do
        if self.read_pages and self.read_pages[page] then
            local x = self:getPageX(page)
            local w = self:getPageX(page, true) - x
            local h = math.ceil(self.read_pages[page][1] * self.span_height * 0.8)
            h = math.max(h, read_min_h) -- so it's noticable
            local y = self.pages_frame_height - self.pages_frame_border - h + 1
            if self.with_page_sep then
                -- We put the blank at the start of a page slot
                x = x + 1
                w = w - 1
                if w > 2 then
                    if page == self.end_page and not self._mirroredUI then
                        w = w - 1 -- some spacing before right border (like we had at start)
                    end
                    if page == self.start_page and self._mirroredUI then
                        w = w - 1
                    end
                end
            end
            local color = Blitbuffer.COLOR_BLACK
            if self.current_session_duration and self.read_pages[page][2] < self.current_session_duration then
                color = Blitbuffer.COLOR_DIM_GRAY
            end
            table.insert(self.pages_markers, {
                x = x, y = y,
                w = w, h = h,
                color = color,
            })
            prev_page_was_read = true
        else
            if self.with_page_sep and not prev_page_was_read then
                local w = Size.line.thin
                local x
                if self._mirroredUI then
                    x = self:getPageX(page, true) - w
                else
                    x = self:getPageX(page)
                end
                local y = self.pages_frame_height - self.pages_frame_border - unread_marker_h + 1
                table.insert(self.pages_markers, {
                    x = x, y = y,
                    w = w, h = unread_marker_h,
                    color = Blitbuffer.COLOR_BLACK,
                })
            end
            prev_page_was_read = false
        end
        -- Indicator for bookmark/highlight type, and current page
        if self.bookmarked_pages[page] then
            local page_bookmark_types = self.bookmarked_pages[page]
            local x = self:getPageX(page)
            local w = self:getPageX(page, true) - x
            x = x + math.ceil(w/2)
            local y = self.pages_frame_height + 1
            -- These 3 icons overlap quite ok, so no need for any shift
            if page_bookmark_types["highlight"] then
                table.insert(self.indicators, {
                    x = x, y = y,
                    c = 0x2592, -- medium shade
                })
            end
            if page_bookmark_types["note"] then
                table.insert(self.indicators, {
                    x = x, y = y,
                    c = 0xF040, -- pencil
                    rotation = -90,
                    shift_x_pct = 0.2, -- 20% looks a bit better
                    -- This glyph is a pencil pointing to the bottom left,
                    -- so we make it point to the top left and align it so
                    -- it points to the page slot it is associated with
                })
            end
            if page_bookmark_types["bookmark"] then
                table.insert(self.indicators, {
                    x = x, y = y,
                    c = 0xF097, -- empty bookmark
                })
            end
        end
        -- Indicator for previous locations
        if self.previous_locations[page] and page ~= self.cur_page then
            local x = self:getPageX(page)
            local w = self:getPageX(page, true) - x
            x = x + math.ceil(w/2)
            local y = self.pages_frame_height + 1
            if self.bookmarked_pages[page] then
                -- Shift it a bit down to keep bookmark glyph(s) readable
                y = y + math.floor(self.span_height / 3)
            end
            local num = self.previous_locations[page]
            table.insert(self.indicators, {
                c = 0x2775 + (num < 10 and num or 10), -- number in solid black circle
                -- c = 0x245F + (num < 20 and num or 20), -- number in white circle
                x = x, y = y,
            })
        end
        -- Extra indicator
        if self.extra_symbols_pages and self.extra_symbols_pages[page] then
            local x = self:getPageX(page)
            local w = self:getPageX(page, true) - x
            x = x + math.ceil(w/2)
            local y = self.pages_frame_height + 1
            if self.bookmarked_pages[page] then
                -- Shift it a bit down to keep bookmark glyph(s) readable
                y = y + math.floor(self.span_height / 3)
            end
            table.insert(self.indicators, {
                c = self.extra_symbols_pages[page],
                x = x, y = y,
            })
        end
        -- Current page indicator
        if page == self.cur_page then
            local x = self:getPageX(page)
            local w = self:getPageX(page, true) - x
            x = x + math.ceil(w/2)
            local y = self.pages_frame_height + 1
            if self.bookmarked_pages[page] then
                -- Shift it a bit down to keep bookmark glyph(s) readable
                y = y + math.floor(self.span_height / 3)
            end
            table.insert(self.indicators, {
                c = 0x25B2, -- black up-pointing triangle
                x = x, y = y,
                face = self.larger_font_face,
            })
        end
        if self.page_texts and self.page_texts[page] then
            -- These have been put on pages free from any other indicator, so
            -- we can show the page number at the very bottom
            local x = self:getPageX(page)
            local w = self:getPageX(page, true) - x - Size.padding.tiny
            table.insert(self.bottom_texts, {
                text = self.page_texts[page].text,
                x = x,
                slot_width = w,
                block = self.page_texts[page].block,
                block_dx = self.page_texts[page].block_dx,
            })
        end
    end
end

function BookMapRow:paintTo(bb, x, y)
    -- Paint background fillers (which are not subwidgets) first
    for _, filler in ipairs(self.background_fillers) do
        bb:paintRect(x + self.pages_frame_offset_x + filler.x, y + filler.y, filler.w, filler.h, filler.color)
    end
    -- Paint regular sub widgets the classic way
    InputContainer.paintTo(self, bb, x, y)
    -- And explicitely paint read pages markers (which are not subwidgets)
    for _, marker in ipairs(self.pages_markers) do
        bb:paintRect(x + self.pages_frame_offset_x + marker.x, y + marker.y, marker.w, marker.h, marker.color)
    end
    -- And explicitely paint indicators (which are not subwidgets)
    for _, indicator in ipairs(self.indicators) do
        local glyph = RenderText:getGlyph(indicator.face or self.font_face, indicator.c)
        local alt_bb
        if indicator.rotation then
            alt_bb = glyph.bb:rotatedCopy(indicator.rotation)
        end
        -- Glyph's bb fit the blackbox of the glyph, so there's no cropping
        -- or complicated positionning to do
        -- By default, just center the glyph at x
        local d_x_pct = indicator.shift_x_pct or 0.5
        local d_x = math.floor(glyph.bb:getWidth() * d_x_pct)
        bb:colorblitFrom(
            alt_bb or glyph.bb,
            x + self.pages_frame_offset_x + indicator.x - d_x,
            y + indicator.y,
            0, 0,
            glyph.bb:getWidth(), glyph.bb:getHeight(),
            Blitbuffer.COLOR_BLACK)
        if alt_bb then
            alt_bb:free()
        end
    end
    -- And explicitely paint bottom texts (which are not subwidgets)
    for _, btext in ipairs(self.bottom_texts) do
        local text_w = TextWidget:new{
            text = btext.text,
            face = self.smaller_font_face,
            padding = 0,
        }
        local d_y = self.height - math.ceil(text_w:getSize().h)
        local d_x
        local text_width = text_w:getWidth()
        local d_width = btext.slot_width - text_width
        if not btext.block then
            -- no block constraint: can be centered
            d_x = math.ceil(d_width / 2)
        else
            if d_width >= 2 * btext.block_dx then
                -- small enough: can be centered
                d_x = math.ceil(d_width / 2)
            elseif btext.block == "left" then
                d_x = btext.block_dx
            else -- "right"
                d_x = d_width - btext.block_dx
            end
        end
        text_w:paintTo(bb, x + self.pages_frame_offset_x + btext.x + d_x, y + d_y)
        text_w:free()
    end
end

-- BookMapWidget: shows a map of content, including TOC, boomarks, read pages, non-linear flows...
local BookMapWidget = InputContainer:new{
    title = _("Book map"),
    -- Focus page: show the BookMapRow containing this page
    -- in the middle of screen
    focus_page = nil,
    -- Should only be nil on the first launch via ReaderThumbnail
    launcher = nil,
    -- Extra symbols to show below pages
    extra_symbols_pages = nil,

    _mirroredUI = BD.mirroredUILayout(),

    -- Make this local subwidget available for reuse by PageBrowser
    BookMapRow = BookMapRow,
}

function BookMapWidget:init()
    -- Compute non-settings-dependant sizes and options
    self.dimen = Geom:new{
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.covers_fullscreen = true -- hint for UIManager:_repaint()

    if Device:hasKeys() then
        self.key_events = {
            Close = { {Input.group.Back}, doc = "close page" },
            ScrollRowUp = {{"Up"}, doc = "scroll up"},
            ScrollRowDown = {{"Down"}, doc = "scrol down"},
            ScrollPageUp = {{Input.group.PgBack}, doc = "prev page"},
            ScrollPageDown = {{Input.group.PgFwd}, doc = "next page"},
        }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{
                ges = "swipe",
                range = self.dimen,
            }
        }
        self.ges_events.MultiSwipe = {
            GestureRange:new{
                ges = "multiswipe",
                range = self.dimen,
            }
        }
        self.ges_events.Tap = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            }
        }
        self.ges_events.Pinch = {
            GestureRange:new{
                ges = "pinch",
                range = self.dimen,
            }
        }
        self.ges_events.Spread = {
            GestureRange:new{
                ges = "spread",
                range = self.dimen,
            }
        }
        -- No need for any long-press handler: page slots may be small and we can't
        -- really target a precise page slot with our fat finger above it...
        -- Tap will zoom the zone in a PageBrowserWidget where things will be clearer
        -- and allow us to get where we want.
        -- (Also, handling "hold" is a bit more complicated when we have our
        -- ScrollableContainer that would also like to handle it.)
    end

    -- No real need for any explicite edge and inter-row padding:
    -- we use the scrollbar width on both sides for balance (we may put a start
    -- page number on the left space), and each BookMapRow will have itself some
    -- blank space at bottom below page slots (where we may put hanging markers
    -- for current page and bookmark/highlights)
    self.scrollbar_width = ScrollableContainer:getScrollbarWidth()
    self.row_width = self.dimen.w - self.scrollbar_width
    self.row_left_spacing = self.scrollbar_width
    self.swipe_hint_bar_width = Screen:scaleBySize(6)

    self.title_bar = TitleBar:new{
        fullscreen = true,
        title = self.title,
        left_icon = "info",
        left_icon_tap_callback = function() self:showHelp() end,
        close_callback = function() self:onClose() end,
        close_hold_callback = function() self:onClose(true) end,
        show_parent = self,
    }
    self.title_bar_h = self.title_bar:getHeight()
    self.crop_height = self.dimen.h - self.title_bar_h - Size.margin.small - self.swipe_hint_bar_width

    -- Guess grid TOC span height from its font size
    -- (it feels this font size does not need to be configurable: too large and
    -- titles will be too easily truncated, too small and they will be unreadable)
    self.toc_span_font_name = "infofont"
    self.toc_span_font_size = 14
    self.toc_span_face = Font:getFace(self.toc_span_font_name, self.toc_span_font_size)
    local test_w = TextWidget:new{
        text = "z",
        face = self.toc_span_face,
    }
    self.span_height = test_w:getSize().h + BookMapRow.toc_span_border
    test_w:free()

    -- Reference font size for flat TOC items, as set (or default) in ReaderToc
    self.reader_toc_font_size = G_reader_settings:readSetting("toc_items_font_size")
            or Menu.getItemFontSize(G_reader_settings:readSetting("toc_items_per_page") or self.ui.toc.toc_items_per_page_default)

    -- Our container of stacked BookMapRows (and TOC titles in flat map mode)
    self.vgroup = VerticalGroup:new{
        align = "left",
    }
    -- We'll handle all events in this main BookMapWidget: none of the vgroup
    -- children have any handler. Hack into vgroup so it doesn't propagate
    -- events needlessly to its children (the slowness gets noticable when
    -- we have many TOC items in flat map mode - the also needless :paintTo()
    -- don't seen to cause such a noticable slowness)
    self.vgroup.propagateEvent = function() return false end

    -- Our scrollable container needs to be known as widget.cropping_widget in
    -- the widget that is passed to UIManager:show() for UIManager to ensure
    -- proper interception of inner widget self repainting/invert (mostly used
    -- when flashing for UI feedback that we want to limit to the cropped area).
    self.cropping_widget = ScrollableContainer:new{
        dimen = Geom:new{
            w = self.dimen.w,
            h = self.crop_height,
        },
        show_parent = self,
        ignore_events = {"swipe"},
        self.vgroup,
    }

    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            self.title_bar,
            self.cropping_widget,
        }
    }

    -- Note: some of these could be cached in ReaderThumbnail, and discarded/updated
    -- on some events (ie. TocUpdated, PageUpdate, AddHhighlight...)
    -- Get some info that shouldn't change across calls to update()
    self.nb_pages = self.ui.document:getPageCount()
    self.ui.toc:fillToc()
    self.cur_page = self.ui.toc.pageno
    self.max_toc_depth = self.ui.toc.toc_depth
    -- Get bookmarks and highlights from ReaderBookmark
    self.bookmarked_pages = self.ui.bookmark:getBookmarkedPages()
    -- Get read page from the statistics plugin if enabled
    self.statistics_enabled = self.ui.statistics and self.ui.statistics:isEnabled()
    self.read_pages = self.ui.statistics and self.ui.statistics:getCurrentBookReadPages()
    self.current_session_duration = self.ui.statistics and (os.time() - self.ui.statistics.start_current_period)
    -- Hidden flows, for first page display, and to draw them gray
    self.has_hidden_flows = self.ui.document:hasHiddenFlows()
    if self.has_hidden_flows and #self.ui.document.flows > 0 then
        self.hidden_flows = {}
        -- Pick into credocument internal data to build a table
        -- of {first_page_number, last_page_number) for each flow
        for flow, tab in ipairs(self.ui.document.flows) do
            table.insert(self.hidden_flows, { tab[1], tab[1]+tab[2]-1 })
        end
    end
    -- Reference page numbers, for first row page display
    self.page_labels = nil
    if self.ui.pagemap and self.ui.pagemap:wantsPageLabels() then
        self.page_labels = self.ui.document:getPageMap()
    end
    -- Location stack
    self.previous_locations = self.ui.link:getPreviousLocationPages()

    -- Compute settings-dependant sizes and options, and build the inner widgets
    self:update()
end

function BookMapWidget:update()
    if not self.focus_page then -- Initial display
        -- Focus (show at the middle of screen) on the BookMapRow that contains
        -- current page
        self.focus_page = self.cur_page
    else
        -- We have a previous focus page: if we have not scrolled around, keep
        -- focusing on this one. Otherwise, use the start_page of the BookMapRow
        -- at the middle of screen as the new focus page.
        if self.initial_scroll_offset_y ~= self.cropping_widget._scroll_offset_y then
            local h = math.min(self.vgroup:getSize().h, self.crop_height)
            local row = self:getBookMapRowNearY(h/2)
            if row then
                self.focus_page = row.start_page
            end
        end
    end

    -- Reset main widgets
    self.vgroup:clear()
    self.cropping_widget:reset()

    -- Flat book map has each TOC item on a new line, and pages graph underneath.
    -- Non-flat book map shows a grid with TOC items following each others.
    self.flat_map = self.ui.doc_settings:readSetting("book_map_flat", false)
    self.toc_depth = self.ui.doc_settings:readSetting("book_map_toc_depth", self.max_toc_depth)
    if self.flat_map then
        self.nb_toc_spans = 0 -- no span shown in grid
    else
        self.nb_toc_spans = self.toc_depth
    end

    self.flat_toc_depth_faces = nil
    if self.flat_map then
        self.flat_toc_depth_faces = {}
        -- Use ReaderToc setting font size for items at the lowest depth
        self.flat_toc_depth_faces[self.toc_depth] = Font:getFace(self.toc_span_font_name, self.reader_toc_font_size)
        for lvl=self.toc_depth-1, 1, -1 do
            -- But increase font size for each upper level
            local inc = 2 * (self.toc_depth - lvl)
            self.flat_toc_depth_faces[lvl] = Font:getFace(self.toc_span_font_name, self.reader_toc_font_size + inc)
        end
        -- Use 1.5em with the reference font size for indenting chapters and their BookMapRow
        self.flat_toc_level_indent = Screen:scaleBySize(self.reader_toc_font_size * 1.5)
    end

    -- Row will contain: nb_toc_spans + page slots + spacing (+ some borders)
    local page_slots_height_ratio = 1 -- default to 1 * span_height
    if not self.statistics_enabled then
        -- If statistics are disabled, we won't show black page slots for read pages.
        -- We can gain a bit of height by reducing the height reserved for these
        -- (don't go too low: we need some height to show the page number on the left).
        if self.flat_map or self.nb_toc_spans == 0 then
            -- Enough to show 4 digits page numbers
            page_slots_height_ratio = 0.7
        elseif self.nb_toc_spans > 0 then
            -- Just enough to show page separators below toc spans
            page_slots_height_ratio = 0.2
        end
    end
    self.row_height = math.ceil((self.nb_toc_spans + page_slots_height_ratio + 1) * self.span_height + 2*BookMapRow.pages_frame_border)

    if self.flat_map then
        -- Max pages per row, when each page slots takes 1px
        self.max_pages_per_row = math.floor(self.row_width - self.row_left_spacing - 2*Size.border.default
                                                - Size.span.horizontal_default*self.toc_depth)
        -- Find out the length of the largest chapter that we may show
        local len
        local max_len = 0
        local p = 1
        for _, item in ipairs(self.ui.toc.toc) do
            if item.depth <= self.toc_depth then
                len = item.page - p + 1
                if len > max_len then max_len = len end
                p = item.page
            end
        end
        len = self.nb_pages - p + 1 -- last chapter
        if len > max_len then max_len = len end
        self.fit_pages_per_row = max_len
    else
        -- Max pages per row, when each page slots takes 1px
        self.max_pages_per_row = math.floor(self.row_width - self.row_left_spacing - 2*Size.border.default)
        -- What can fit without scrollbar
        local fit_nb_rows = math.floor(self.crop_height / self.row_height)
        self.fit_pages_per_row = math.ceil(self.nb_pages / fit_nb_rows)
    end
    self.min_pages_per_row = 10
    -- If page slots are at least 4 pixels wide, we can steal one to act as a 1px blank separator
    self.max_pages_per_row_with_sep = math.floor(self.max_pages_per_row / 4)
    if self.fit_pages_per_row < self.min_pages_per_row then
        self.fit_pages_per_row = self.min_pages_per_row
    end
    if self.fit_pages_per_row > self.max_pages_per_row then
        self.fit_pages_per_row = self.max_pages_per_row
    end

    -- Show the whole book without scrollbar initially
    self.pages_per_row = self.ui.doc_settings:readSetting("book_map_pages_per_row", self.fit_pages_per_row)
    self.page_slot_width = nil -- will be fetched from the first BookMapRow

    -- Build BookMapRows as we walk the ToC
    local toc = self.ui.toc.toc
    local toc_idx = 1
    local cur_toc_items = {}
    local p_start = 1
    local cur_left_spacing = self.row_left_spacing -- updated when flat_map with previous TOC item indentation
    local cur_page_label_idx = 1
    while true do
        local p_max = p_start + self.pages_per_row - 1 -- max page number in this row
        local p_end = math.min(p_max, self.nb_pages) -- last book page in this row
        -- Find out the toc items that can be shown on this row
        local row_toc_items = {}
        while toc_idx <= #toc do
            local item = toc[toc_idx]
            if item.page > p_max then
                -- This TOC item will close previous items and start on the next row
                break
            end
            if item.depth <= self.toc_depth then -- ignore lower levels we won't show
                if self.flat_map then
                    if item.page == p_start then
                        cur_left_spacing = self.row_left_spacing + self.flat_toc_level_indent * (item.depth-1)
                        local txt_max_width = self.row_width - cur_left_spacing
                        table.insert(self.vgroup, HorizontalGroup:new{
                            HorizontalSpan:new{
                                width = cur_left_spacing,
                            },
                            TextBoxWidget:new{
                                text = self.ui.toc:cleanUpTocTitle(item.title, true),
                                width = txt_max_width,
                                face = self.flat_toc_depth_faces[item.depth],
                            }
                        })
                        -- Add a bit more spacing for the BookMapRow(s) underneath this Toc item title
                        -- (so the page number painted in this spacing feels included in the indentation)
                        cur_left_spacing = cur_left_spacing + Size.span.horizontal_default
                        -- Note: this variable indentation may make the page slot widths variable across
                        -- rows from different levels (and self.fit_pages_per_row not really accurate) :/
                        -- Hopefully, it won't be noticable.
                    else
                        p_max = item.page - 1
                        p_end = p_max
                        -- Will be reprocessed on a new row
                        break
                    end
                else
                    -- An item at level N closes all previous items at level >= N
                    for lvl = item.depth, self.toc_depth do
                        local done_toc_item = cur_toc_items[lvl]
                        cur_toc_items[lvl] = nil
                        if done_toc_item then
                            done_toc_item.p_end = math.max(item.page - 1, done_toc_item.p_start)
                            if done_toc_item.p_end >= p_start then
                                -- Can go into row_toc_items[lvl]
                                if done_toc_item.p_start < p_start then
                                    done_toc_item.p_start = p_start
                                    done_toc_item.started_before = true -- no left margin
                                end
                                if not row_toc_items[lvl] then
                                    row_toc_items[lvl] = {}
                                end
                                -- We're done with it, we can just move it
                                table.insert(row_toc_items[lvl], done_toc_item)
                            end
                        end
                    end
                    cur_toc_items[item.depth] = {
                        title = item.title,
                        p_start = item.page,
                        p_end = nil,
                    }
                end
            end
            toc_idx = toc_idx + 1
        end
        local is_last_row = p_end == self.nb_pages
        -- We may have current toc_items that are active and may continue on next row
        -- Add a slightly adjusted copy of the current ones to row_toc_items
        for lvl = 1, self.nb_toc_spans do -- (no-op/no-loop if flat_map)
            local active_toc_item = cur_toc_items[lvl]
            if active_toc_item then
                local copied_toc_item = {}
                for k,v in next, active_toc_item, nil do copied_toc_item[k] = v end
                if copied_toc_item.p_start < p_start then
                    copied_toc_item.p_start = p_start
                    copied_toc_item.started_before = true -- no left margin
                end
                copied_toc_item.p_end = p_end
                copied_toc_item.continues_after = not is_last_row -- no right margin (except if last row)
                -- Look at next TOC item to see if it would close this one
                local coming_up_toc_item = toc[toc_idx]
                if coming_up_toc_item and coming_up_toc_item.page == p_max+1 and coming_up_toc_item.depth <= lvl then
                    copied_toc_item.continues_after = false -- right margin
                end
                if not row_toc_items[lvl] then
                    row_toc_items[lvl] = {}
                end
                table.insert(row_toc_items[lvl], copied_toc_item)
            end
        end

        -- Get the page number to display at start of row
        local start_page_text
        if self.page_labels then
            local label
            for idx=cur_page_label_idx, #self.page_labels do
                local item = self.page_labels[idx]
                if item.page > p_start then
                    break
                end
                label = item.label
                cur_page_label_idx = idx
            end
            if label then
                start_page_text = self.ui.pagemap:cleanPageLabel(label)
            end
        elseif self.has_hidden_flows then
            local flow = self.ui.document:getPageFlow(p_start)
            if flow == 0 then
                start_page_text = tostring(self.ui.document:getPageNumberInFlow(p_start))
            else
                -- start_page_text = string.format("[%d]%d", self.ui.document:getPageNumberInFlow(p_start), self.ui.document:getPageFlow(p_start))
                -- start_page_text = string.format("/%d\\", self.ui.document:getPageFlow(p_start))
                -- Just don't display anything
                start_page_text = nil
            end
        else
            start_page_text = tostring(p_start)
        end
        if start_page_text then
            start_page_text = table.concat(util.splitToChars(start_page_text), "\n")
        else
            start_page_text = ""
        end

        local row = BookMapRow:new{
            height = self.row_height,
            width = self.row_width,
            show_parent = self,
            left_spacing = cur_left_spacing,
            nb_toc_spans = self.nb_toc_spans,
            span_height = self.span_height,
            font_face = self.toc_span_face,
            start_page_text = start_page_text,
            start_page = p_start,
            end_page = p_end,
            pages_per_row = self.pages_per_row,
            cur_page = self.cur_page,
            with_page_sep = self.pages_per_row < self.max_pages_per_row_with_sep,
            toc_items = row_toc_items,
            bookmarked_pages = self.bookmarked_pages,
            previous_locations = self.previous_locations,
            extra_symbols_pages = self.extra_symbols_pages,
            hidden_flows = self.hidden_flows,
            read_pages = self.read_pages,
            current_session_duration = self.current_session_duration,
        }
        table.insert(self.vgroup, row)
        if not self.page_slot_width then
            self.page_slot_width = row.page_slot_width
        end
        if is_last_row then
            break
        end
        p_start = p_max + 1
    end

    -- Have main VerticalGroup size and subwidgets' offsets computed
    self.vgroup:getSize()

    -- Scroll so we get the focus page at the middle of screen
    local row, row_idx, row_y, row_h = self:getMatchingVGroupRow(function(r, r_y, r_h) -- luacheck: no unused
        return r.start_page and self.focus_page >= r.start_page and self.focus_page <= r.end_page
    end)
    if row_y then
        local top_y = row_y + row_h/2 - self.crop_height/2
        -- Align it so that we don't see any truncated BookMapRow at top
        row, row_idx, row_y, row_h = self:getMatchingVGroupRow(function(r, r_y, r_h)
            return r_y < top_y and r_y + r_h > top_y
        end)
        if row then
            if top_y - row_y > row_y + row_h - top_y then
                -- Less adjustment if we scroll to align the next row
                top_y = row_y + row_h
            else
                top_y = row_y
            end
        end
        if top_y > 0 then
            self.cropping_widget:initState() -- anticipate this (otherwise delayed and done at :paintTo() time)
            if self.cropping_widget._is_scrollable then
                self.cropping_widget:_scrollBy(0, top_y)
            end
        end
    end
    self.initial_scroll_offset_y = self.cropping_widget._scroll_offset_y

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end


function BookMapWidget:showHelp()
    UIManager:show(InfoMessage:new{
        text = _([[
Book map displays an overview of the book content.

If statistics are enabled, black bars are shown for already read pages (gray for pages read in the current reading session). Their heights vary with the time spent reading the page.
Chapters are shown above their pages.
Under the pages can be found some indicators:
▲ current page
❶ ❷ … previous locations
▒ highlighted text
 highlighted text with notes
 bookmarked page
▢ focused page when coming from Pages browser

Tap on a location in the book to browse thumbnails of the pages there.
Swipe along the left screen edge to change the level of chapters to include in the book map, and the type of book map (grid or flat) when crossing the level 0.
Swipe along the bottom screen edge to change the width of page slots.
Swipe or pan vertically on content to scroll.
Any multiswipe will close the book map.

On a newly opened book, the book map will start in grid mode showing all chapter levels, fitting on a single screen, to give the best initial overview of the book's content.]]),
    })
end

function BookMapWidget:onClose(close_all_parents)
    -- Close this widget
    logger.dbg("closing BookMapWidget")
    UIManager:close(self)
    if self.launcher then
        -- We were launched by a PageBrowserWidget, don't do any cleanup.
        if close_all_parents then
            -- The last one of these (which has no launcher attribute)
            -- will do the cleanup below.
            self.launcher:onClose(true)
        else
            UIManager:setDirty(self.launcher, "ui")
        end
    else
        -- Remove all thumbnails generated for a different target size than
        -- the last one used (no need to keep old sizes if the user played
        -- with nb_cols/nb_rows, as on next opening, we just need the ones
        -- with the current size to be available)
        self.ui.thumbnail:tidyCache()
        -- Force a GC to free the memory used by the widgets and tiles
        -- (delay it a bit so this pause is less noticable)
        UIManager:scheduleIn(0.5, function()
            collectgarbage()
            collectgarbage()
        end)
        -- As we're getting back to Reader, do a full flashing refresh to remove
        -- any ghost trace of thumbnails or black page slots
        UIManager:setDirty(self.ui.dialog, "full")
    end
    return true
end

function BookMapWidget:getMatchingVGroupRow(check_func)
    -- Generic Vertical subwidget search function.
    -- We use some of VerticalGroup's internal data, no need
    -- to keep public copies of these data in here
    for i=1, #self.vgroup do
        local row = self.vgroup[i]
        local y = self.vgroup._offsets[i].y
        local h = (i < #self.vgroup and self.vgroup._offsets[i+1].y or self.vgroup._size.h) - y
        if check_func(row, y, h) then
            return row, i, y, h
        end
    end
end

function BookMapWidget:getVGroupRowAtY(y)
    -- y is expected relative to the ScrollableContainer crop top
    -- (if y is from a screen coordinate, substract 'self.title_bar_h' before calling this)
    y = y + self.cropping_widget._scroll_offset_y
    return self:getMatchingVGroupRow(function(r, r_y, r_h)
        return y >= r_y and y < r_y + r_h
    end)
end

function BookMapWidget:getBookMapRowNearY(y)
    -- y is expected relative to the ScrollableContainer crop top
    -- (if y is from a screen coordinate, substract 'self.title_bar_h' before calling this)
    y = y + self.cropping_widget._scroll_offset_y
    -- Return the BookMapRow at y, or if the vgroup element is a ToC
    -- title (in flat_map mode), return the follow up BookMapRow
    return self:getMatchingVGroupRow(function(r, r_y, r_h)
        return y < r_y + r_h and r.start_page
    end)
end

function BookMapWidget:onScrollPageUp()
    -- Show previous content, ensuring any truncated widget at top is now full at bottom
    local scroll_offset_y = self.cropping_widget._scroll_offset_y
    local row, row_idx, row_y, row_h = self:getVGroupRowAtY(-1) -- luacheck: no unused
    local to_keep = 0
    if row then
        to_keep = row_h - (scroll_offset_y - row_y)
    end
    self.cropping_widget:_scrollBy(0, -(self.crop_height - to_keep))
    return true
end

function BookMapWidget:onScrollPageDown()
    -- Show next content, ensuring any truncated widget at bottom is now full at top
    local scroll_offset_y = self.cropping_widget._scroll_offset_y
    local row, row_idx, row_y, row_h = self:getVGroupRowAtY(self.crop_height) -- luacheck: no unused
    if row then
        self.cropping_widget:_scrollBy(0, row_y - scroll_offset_y)
    else
        self.cropping_widget:_scrollBy(0, self.crop_height)
    end
    return true
end

function BookMapWidget:onScrollRowUp()
    local scroll_offset_y = self.cropping_widget._scroll_offset_y
    local row, row_idx, row_y, row_h = self:getVGroupRowAtY(-1) -- luacheck: no unused
    if row then
        self.cropping_widget:_scrollBy(0, row_y - scroll_offset_y)
    end
    return true
end

function BookMapWidget:onScrollRowDown()
    local scroll_offset_y = self.cropping_widget._scroll_offset_y
    local row, row_idx, row_y, row_h = self:getVGroupRowAtY(0) -- luacheck: no unused
    if row then
        self.cropping_widget:_scrollBy(0, row_y + row_h - scroll_offset_y)
    end
    return true
end

function BookMapWidget:saveSettings(reset)
    if reset then
        self.flat_map = nil
        self.toc_depth = nil
        self.pages_per_row = nil
    end
    self.ui.doc_settings:saveSetting("book_map_flat", self.flat_map)
    self.ui.doc_settings:saveSetting("book_map_toc_depth", self.toc_depth)
    self.ui.doc_settings:saveSetting("book_map_pages_per_row", self.pages_per_row)
end

function BookMapWidget:updateTocDepth(depth, flat)
    -- if flat == nil, consider value relative, and allow toggling
    -- flatness when crossing 0
    local new_toc_depth = self.toc_depth
    local new_flat_map = self.flat_map
    if flat == nil then
        if self.flat_map then
            -- Reverse increment if flat_map
            new_toc_depth = new_toc_depth - depth
        else
            new_toc_depth = new_toc_depth + depth
        end
        if new_toc_depth < 0 then
            new_toc_depth = - new_toc_depth
            new_flat_map = not new_flat_map
        end
    else
        new_toc_depth = depth
        new_flat_map = flat
    end
    if new_toc_depth < 0 then
        new_toc_depth = 0
    end
    if new_toc_depth > self.max_toc_depth then
        new_toc_depth = self.max_toc_depth
    end
    if new_toc_depth == self.toc_depth and new_flat_map == self.flat_map then
        return false
    end
    self.toc_depth = new_toc_depth
    self.flat_map = new_flat_map
    self:saveSettings()
    return true
end

function BookMapWidget:updatePagesPerRow(value, relative)
    local new_pages_per_row
    if relative then
        new_pages_per_row = self.pages_per_row + value
    else
        new_pages_per_row = value
    end
    if new_pages_per_row < self.min_pages_per_row then
        new_pages_per_row = self.min_pages_per_row
    end
    if new_pages_per_row > self.max_pages_per_row then
        new_pages_per_row = self.max_pages_per_row
    end
    if new_pages_per_row == self.pages_per_row then
        return false
    end
    self.pages_per_row = new_pages_per_row
    self:saveSettings()
    return true
end

function BookMapWidget:onSwipe(arg, ges)
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if (not self._mirroredUI and ges.pos.x < Screen:getWidth() * 1/8) or
           (self._mirroredUI and ges.pos.x > Screen:getWidth() * 7/8) then
        -- Swipe along the left screen edge: increase/decrease toc levels shown
        if direction == "north" or direction == "south" then
            local rel = direction == "south" and 1 or -1
            if self:updateTocDepth(rel, nil) then
                self:update()
            end
            return true
        end
    end
    if ges.pos.y > Screen:getHeight() * 7/8 then
        -- Swipe along the bottom screen edge: increase/decrease pages per row
        if direction == "west" or direction == "east" then
            -- Have a swipe distance 0.8 x screen width do *2 or *1/2
            local ratio = ges.distance / Screen:getWidth()
            local new_pages_per_row
            if direction == "west" then -- increase pages per row
                new_pages_per_row = math.ceil(self.pages_per_row * (1 + ratio))
            else
                new_pages_per_row = math.floor(self.pages_per_row / (1 + ratio))
            end
            -- If we are crossing the ideal fit_pages_per_row, stop on it
            if (self.pages_per_row < self.fit_pages_per_row and new_pages_per_row > self.fit_pages_per_row)
                    or (self.pages_per_row > self.fit_pages_per_row and new_pages_per_row < self.fit_pages_per_row) then
                new_pages_per_row = self.fit_pages_per_row
            end
            if self:updatePagesPerRow(new_pages_per_row) then
                self:update()
            end
            return true
        end
    end
    -- Let our MovableContainer handle other swipes:
    -- return self.cropping_widget:onScrollableSwipe(arg, ges)
    -- No, we prefer not to, and have swipe north/south do full prev/next page
    -- rather than based on the swipe distance
    if direction == "north" then
        return self:onScrollPageDown()
    elseif direction == "south" then
        return self:onScrollPageUp()
    elseif direction == "west" or direction == "east" then
        return true
    else -- diagonal swipe
        -- trigger full refresh
        UIManager:setDirty(nil, "full")
        -- a long diagonal swipe may also be used for taking a screenshot,
        -- so let it propagate
        return false
    end
end

function BookMapWidget:onPinch(arg, ges)
    local updated = false
    if ges.direction == "horizontal" or ges.direction == "diagonal" then
        local new_pages_per_row = math.ceil(self.pages_per_row * 1.5)
        if (self.pages_per_row < self.fit_pages_per_row and new_pages_per_row > self.fit_pages_per_row)
                or (self.pages_per_row > self.fit_pages_per_row and new_pages_per_row < self.fit_pages_per_row) then
            new_pages_per_row = self.fit_pages_per_row
        end
        if self:updatePagesPerRow(new_pages_per_row) then
            updated = true
        end
    end
    if ges.direction == "vertical" or ges.direction == "diagonal" then
        -- Keep current flat map mode
        if self:updateTocDepth(self.toc_depth-1, self.flat_map) then
            updated = true
        else
            -- Already at 0: toggle flat mode, stay at 0 (no visual feedback though...)
            if self:updateTocDepth(0, not self.flat_map) then
                updated = true
            end
        end
    end
    if updated then
        self:update()
    end
    return true
end

function BookMapWidget:onSpread(arg, ges)
    local updated = false
    if ges.direction == "horizontal" or ges.direction == "diagonal" then
        local new_pages_per_row = math.floor(self.pages_per_row / 1.5)
        if (self.pages_per_row < self.fit_pages_per_row and new_pages_per_row > self.fit_pages_per_row)
                or (self.pages_per_row > self.fit_pages_per_row and new_pages_per_row < self.fit_pages_per_row) then
            new_pages_per_row = self.fit_pages_per_row
        end
        if self:updatePagesPerRow(new_pages_per_row) then
            updated = true
        end
    end
    if ges.direction == "vertical" or ges.direction == "diagonal" then
        if self:updateTocDepth(self.toc_depth+1, self.flat_map) then
            updated = true
        end
    end
    if updated then
        self:update()
    end
    return true
end

function BookMapWidget:onMultiSwipe(arg, ges)
    -- Swipe south (the usual shortcut for closing a full screen window)
    -- is used for navigation. Swipe left/right are free, but a little
    -- unusual for the purpose of closing.
    -- So, allow for quick closing with any multiswipe.
    self:onClose()
    return true
end

function BookMapWidget:onTap(arg, ges)
    if ges.pos:notIntersectWith(self.cropping_widget.dimen) then
        return true
    end
    local x, y = ges.pos.x, ges.pos.y
    local row, row_idx, row_y, row_h = self:getVGroupRowAtY(y-self.title_bar_h) -- luacheck: no unused
    if not row or not row.start_page then
        -- not a BookMapRow, probably a TOC title
        return true
    end
    if self._mirroredUI then
        x = x - self.scrollbar_width
    end
    local page = row:getPageAtX(x)
    if page then
        local PageBrowserWidget = require("ui/widget/pagebrowserwidget")
        UIManager:show(PageBrowserWidget:new{
            launcher = self,
            ui = self.ui,
            focus_page = page,
        })
    end
    return true
end

function BookMapWidget:paintTo(bb, x, y)
    -- Paint regular sub widgets the classic way
    InputContainer.paintTo(self, bb, x, y)
    -- And explicitely paint "swipe" hints along the left and bottom borders
    self:paintLeftVerticalSwipeHint(bb, x, y)
    self:paintBottomHorizontalSwipeHint(bb, x, y)
end

function BookMapWidget:paintLeftVerticalSwipeHint(bb, x, y)
    -- Vertical bar with a part of it darker, as a scale showing
    -- selected flat_map and toc_depth. In gray so it's visible
    -- when you look at it, but not distracting when you don't.
    local v = self.vs_hint_info
    if not v then
        -- Compute and remember sizes, positions and info
        v = {}
        v.width = self.swipe_hint_bar_width
        if self._mirroredUI then
            v.left = Screen:getWidth() - v.width
        else
            v.left = 0
        end
        v.top = self.title_bar_h + math.floor(self.crop_height * 1/6)
        v.height = math.floor(self.crop_height * 4/6)
        v.nb_units = self.max_toc_depth * 2 + 1
        v.unit_h = math.floor(v.height / v.nb_units)
        self.vs_hint_info = v
    end
    -- Paint a vertical light gray bar
    bb:paintRect(v.left, v.top, v.width, v.height, Blitbuffer.COLOR_LIGHT_GRAY)
    -- And paint a part of it in a darker gray
    local unit_idx -- starts from 0
    if self.flat_map then -- upper part of the vertical bar
        unit_idx = self.max_toc_depth - self.toc_depth
    else -- lower part of the vertical bar
        unit_idx = self.max_toc_depth + self.toc_depth
    end
    local dy = unit_idx * v.unit_h
    if unit_idx == v.nb_units - 1 then
        -- avoid possible rounding error for last unit
        dy = v.height - v.unit_h
    end
    bb:paintRect(v.left, v.top + dy, v.width, v.unit_h, Blitbuffer.COLOR_DARK_GRAY)
end

function BookMapWidget:paintBottomHorizontalSwipeHint(bb, x, y)
    -- Horizontal bar with a part of it darker, as a scale showing
    -- selected pages_per_row.
    local h = self.hs_hint_info
    if not h then
        -- Compute and remember sizes, positions and info
        h = {}
        h.height = self.swipe_hint_bar_width
        h.top = Screen:getHeight() - h.height
        h.width = math.floor(Screen:getWidth() * 4/6)
        h.left = math.floor(Screen:getWidth() * 1/6)
        -- We show a fixed width handle with a granular dx
        h.hint_w = math.floor(h.width / 8)
        h.max_dx = h.width - h.hint_w
        self.hs_hint_info = h
    end
    -- Paint a horizontal light gray bar
    bb:paintRect(h.left, h.top, h.width, h.height, Blitbuffer.COLOR_LIGHT_GRAY)
    -- And paint a part of it in a darker gray
    -- (Somebody good at maths could probably do better than this... which
    -- could be related to the increment/ratio we use in onSwipe)
    local cur = self.pages_per_row - self.min_pages_per_row
    local max = self.max_pages_per_row - self.min_pages_per_row
    local dx = math.floor(h.max_dx*(1-math.log(1+cur)/math.log(1+max)))
    if self._mirroredUI then
        dx = h.max_dx - dx
    end
    bb:paintRect(h.left + dx, h.top, h.hint_w, h.height, Blitbuffer.COLOR_DARK_GRAY)
end

return BookMapWidget

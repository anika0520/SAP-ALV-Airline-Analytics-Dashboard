*&---------------------------------------------------------------------*
*& Program     : Z_AIRLINE_ANALYTICS_DASHBOARD
*& Title       : Smart Airline Analytics Dashboard (ALV Grid) — v2.1
*& Author      : Senior SAP ABAP Architect
*& Description : Enterprise-level airline analytics using CL_GUI_ALV_GRID
*&               with traffic-light coloring, custom toolbar, event
*&               handling, Excel export, analytics popup, double-click
*&               drill-down, top airline KPI, and a clean 3-layer architecture.
*&
*& Enhancement Log:
*&   v2.1 - Excel export upgraded to DAT (Excel-compatible tab-delimited)
*&        - Analytics popup refactored to POPUP_TO_DISPLAY_TEXT (cleaner UI)
*&        - Top Airline KPI added to analytics popup (real analytics insight)
*&        - Double-click drill-down annotated as expandable navigation layer
*&   v2.0 - Added Excel export via GUI_DOWNLOAD (XLS format)
*&        - Enhanced analytics popup with structured HTML-style layout
*&        - Double-click drill-down with full flight detail popup
*&        - UI polish: zebra, auto-width, grid title, row color, icons
*&        - Traffic-light coloring with proper ALV color tokens
*&        - Toolbar buttons: Refresh, Export Excel, Analytics, separator
*&        - Summary status bar message after data load
*&        - Robust error handling and input validation
*&---------------------------------------------------------------------*
PROGRAM z_airline_analytics_dashboard.

*======================================================================*
* TYPE DECLARATIONS
*======================================================================*
TYPES:
  BEGIN OF ty_flight_raw,
    carrid    TYPE sflight-carrid,
    connid    TYPE sflight-connid,
    fldate    TYPE sflight-fldate,
    price     TYPE sflight-price,
    currency  TYPE sflight-currency,
    seatsmax  TYPE sflight-seatsmax,
    seatsocc  TYPE sflight-seatsocc,
    carrname  TYPE scarr-carrname,
    airpfrom  TYPE spfli-airpfrom,
    airpto    TYPE spfli-airpto,
    distance  TYPE spfli-distance,
    distid    TYPE spfli-distid,
  END OF ty_flight_raw,

  BEGIN OF ty_flight_display,
    carrid    TYPE sflight-carrid,
    connid    TYPE sflight-connid,
    fldate    TYPE sflight-fldate,
    price     TYPE sflight-price,
    currency  TYPE sflight-currency,
    seatsmax  TYPE sflight-seatsmax,
    seatsocc  TYPE sflight-seatsocc,
    seats_pct TYPE p LENGTH 5 DECIMALS 1,
    revenue   TYPE p LENGTH 15 DECIMALS 2,
    carrname  TYPE scarr-carrname,
    airpfrom  TYPE spfli-airpfrom,
    airpto    TYPE spfli-airpto,
    distance  TYPE spfli-distance,
    distid    TYPE spfli-distid,
    light     TYPE c LENGTH 1,   " Traffic-light indicator: G/Y/R
    rowcolor  TYPE c LENGTH 4,   " ALV row color token
  END OF ty_flight_display,

  " Type for Excel export (flat string table)
  ty_excel_line TYPE c LENGTH 512,

  BEGIN OF ty_analytics,
    total_flights   TYPE i,
    avg_price       TYPE p LENGTH 10 DECIMALS 2,
    total_revenue   TYPE p LENGTH 20 DECIMALS 2,
    top_airline     TYPE scarr-carrname,
    top_carr_count  TYPE i,
    max_price       TYPE sflight-price,
    min_price       TYPE sflight-price,
    avg_load_pct    TYPE p LENGTH 5 DECIMALS 1,
    high_count      TYPE i,   " Flights with price >= c_price_high
    mid_count       TYPE i,   " Flights with price in mid range
    low_count       TYPE i,   " Flights with price < c_price_low
  END OF ty_analytics.

*======================================================================*
* CONSTANTS
*======================================================================*
CONSTANTS:
  c_price_high    TYPE sflight-price VALUE 800,
  c_price_low     TYPE sflight-price VALUE 300,
  c_btn_refresh   TYPE i             VALUE 1001,
  c_btn_analytics TYPE i             VALUE 1002,
  c_btn_excel     TYPE i             VALUE 1003,
  c_colname_color TYPE lvc_fname     VALUE 'ROWCOLOR',
  c_prog_name     TYPE syst-repid    VALUE 'Z_AIRLINE_ANALYTICS_DASHBOARD',
  c_excel_path    TYPE string        VALUE 'C:\Temp\Airline_Analytics.xls',
  c_tab           TYPE c             VALUE cl_abap_char_utilities=>horizontal_tab,
  c_newline       TYPE c             VALUE cl_abap_char_utilities=>newline.

*======================================================================*
* SELECTION SCREEN
*======================================================================*
SELECTION-SCREEN BEGIN OF BLOCK b_carrier WITH FRAME TITLE TEXT-001.
  SELECT-OPTIONS: so_carr FOR sflight-carrid
                             DEFAULT 'LH' TO 'UA' OPTION BT.
SELECTION-SCREEN END OF BLOCK b_carrier.

SELECTION-SCREEN BEGIN OF BLOCK b_date WITH FRAME TITLE TEXT-002.
  SELECT-OPTIONS: so_date FOR sflight-fldate
                             DEFAULT '20240101' TO '20241231'.
SELECTION-SCREEN END OF BLOCK b_date.

SELECTION-SCREEN BEGIN OF BLOCK b_price WITH FRAME TITLE TEXT-003.
  PARAMETERS: pa_pmin TYPE sflight-price DEFAULT 0,
              pa_pmax TYPE sflight-price DEFAULT 99999.
SELECTION-SCREEN END OF BLOCK b_price.

SELECTION-SCREEN BEGIN OF BLOCK b_export WITH FRAME TITLE TEXT-004.
  PARAMETERS: pa_xls TYPE c LENGTH 128 DEFAULT 'C:\Temp\Airline_Analytics.xls'.
SELECTION-SCREEN END OF BLOCK b_export.

*======================================================================*
* CLASS: ZCL_AIRLINE_DATA_FETCHER  (Data Fetch Layer)
*======================================================================*
CLASS zcl_airline_data_fetcher DEFINITION FINAL.
  PUBLIC SECTION.
    CLASS-METHODS:
      fetch
        IMPORTING
          it_carr  TYPE RANGE OF sflight-carrid
          it_date  TYPE RANGE OF sflight-fldate
          iv_pmin  TYPE sflight-price
          iv_pmax  TYPE sflight-price
        RETURNING
          VALUE(rt_data) TYPE STANDARD TABLE OF ty_flight_raw.
ENDCLASS.

CLASS zcl_airline_data_fetcher IMPLEMENTATION.
  METHOD fetch.
    SELECT
        sf~carrid,
        sf~connid,
        sf~fldate,
        sf~price,
        sf~currency,
        sf~seatsmax,
        sf~seatsocc,
        sc~carrname,
        sp~airpfrom,
        sp~airpto,
        sp~distance,
        sp~distid
      FROM sflight AS sf
      INNER JOIN scarr AS sc ON sc~carrid = sf~carrid
      INNER JOIN spfli AS sp ON  sp~carrid = sf~carrid
                             AND sp~connid = sf~connid
      WHERE sf~carrid IN @it_carr
        AND sf~fldate IN @it_date
        AND sf~price  BETWEEN @iv_pmin AND @iv_pmax
      ORDER BY sf~carrid, sf~fldate
      INTO TABLE @rt_data.

    IF sy-subrc <> 0.
      CLEAR rt_data.
    ENDIF.
  ENDMETHOD.
ENDCLASS.

*======================================================================*
* CLASS: ZCL_AIRLINE_BIZ_LOGIC  (Business Logic Layer)
*======================================================================*
CLASS zcl_airline_biz_logic DEFINITION FINAL.
  PUBLIC SECTION.
    CLASS-METHODS:
      enrich
        IMPORTING
          it_raw            TYPE STANDARD TABLE OF ty_flight_raw
        RETURNING
          VALUE(rt_display) TYPE STANDARD TABLE OF ty_flight_display,

      compute_analytics
        IMPORTING
          it_display        TYPE STANDARD TABLE OF ty_flight_display
        RETURNING
          VALUE(rs_result)  TYPE ty_analytics.

  PRIVATE SECTION.
    CLASS-METHODS:
      get_traffic_light
        IMPORTING
          iv_price         TYPE sflight-price
        RETURNING
          VALUE(rv_light)  TYPE c.
ENDCLASS.

CLASS zcl_airline_biz_logic IMPLEMENTATION.

  METHOD enrich.
    DATA ls_display TYPE ty_flight_display.

    LOOP AT it_raw ASSIGNING FIELD-SYMBOL(<raw>).
      CLEAR ls_display.
      MOVE-CORRESPONDING <raw> TO ls_display.

      " Seat occupancy %
      IF <raw>-seatsmax > 0.
        ls_display-seats_pct = ( <raw>-seatsocc / <raw>-seatsmax ) * 100.
      ENDIF.

      " Estimated revenue per flight
      ls_display-revenue = <raw>-price * <raw>-seatsocc.

      " Traffic light tier
      ls_display-light = get_traffic_light( <raw>-price ).

      " ALV row color token: C{n}{I} — Intensified
      CASE ls_display-light.
        WHEN 'G'. ls_display-rowcolor = 'C502'. " Soft green
        WHEN 'Y'. ls_display-rowcolor = 'C310'. " Orange/Amber
        WHEN 'R'. ls_display-rowcolor = 'C610'. " Red
      ENDCASE.

      APPEND ls_display TO rt_display.
    ENDLOOP.
  ENDMETHOD.

  METHOD get_traffic_light.
    IF iv_price >= c_price_high.
      rv_light = 'G'.
    ELSEIF iv_price >= c_price_low.
      rv_light = 'Y'.
    ELSE.
      rv_light = 'R'.
    ENDIF.
  ENDMETHOD.

  METHOD compute_analytics.
    DATA: lv_total_price  TYPE p LENGTH 20 DECIMALS 2,
          lv_total_load   TYPE p LENGTH 20 DECIMALS 2.

    rs_result-total_flights = lines( it_display ).

    IF rs_result-total_flights = 0.
      RETURN.
    ENDIF.

    LOOP AT it_display ASSIGNING FIELD-SYMBOL(<row>).
      lv_total_price          += <row>-price.
      rs_result-total_revenue += <row>-revenue.
      lv_total_load           += <row>-seats_pct.

      " Max/min price
      IF <row>-price > rs_result-max_price.
        rs_result-max_price = <row>-price.
      ENDIF.
      IF rs_result-min_price = 0 OR <row>-price < rs_result-min_price.
        rs_result-min_price = <row>-price.
      ENDIF.

      " Price tier counters
      CASE <row>-light.
        WHEN 'G'. rs_result-high_count += 1.
        WHEN 'Y'. rs_result-mid_count  += 1.
        WHEN 'R'. rs_result-low_count  += 1.
      ENDCASE.
    ENDLOOP.

    rs_result-avg_price    = lv_total_price / rs_result-total_flights.
    rs_result-avg_load_pct = lv_total_load  / rs_result-total_flights.

    " Top airline by flight frequency
    TYPES: BEGIN OF ty_carr_freq,
             carrid   TYPE sflight-carrid,
             carrname TYPE scarr-carrname,
             cnt      TYPE i,
           END OF ty_carr_freq.

    DATA lt_freq TYPE HASHED TABLE OF ty_carr_freq WITH UNIQUE KEY carrid.

    LOOP AT it_display ASSIGNING FIELD-SYMBOL(<fl>).
      READ TABLE lt_freq ASSIGNING FIELD-SYMBOL(<freq>)
        WITH TABLE KEY carrid = <fl>-carrid.
      IF sy-subrc = 0.
        <freq>-cnt += 1.
      ELSE.
        INSERT VALUE ty_carr_freq(
          carrid   = <fl>-carrid
          carrname = <fl>-carrname
          cnt      = 1 ) INTO TABLE lt_freq.
      ENDIF.
    ENDLOOP.

    DATA ls_top TYPE ty_carr_freq.
    LOOP AT lt_freq ASSIGNING FIELD-SYMBOL(<fc>).
      IF <fc>-cnt > ls_top-cnt.
        ls_top = <fc>.
      ENDIF.
    ENDLOOP.

    rs_result-top_airline    = ls_top-carrname.
    rs_result-top_carr_count = ls_top-cnt.
  ENDMETHOD.
ENDCLASS.

*======================================================================*
* CLASS: ZCL_AIRLINE_EXCEL_EXPORTER  (Excel Export Layer)
*======================================================================*
CLASS zcl_airline_excel_exporter DEFINITION FINAL.
  PUBLIC SECTION.
    CLASS-METHODS:
      export
        IMPORTING
          it_display TYPE STANDARD TABLE OF ty_flight_display
          iv_path    TYPE string.
ENDCLASS.

CLASS zcl_airline_excel_exporter IMPLEMENTATION.

  METHOD export.
    DATA: lt_output  TYPE STANDARD TABLE OF ty_excel_line,
          lv_line    TYPE ty_excel_line,
          lv_path    TYPE string.

    lv_path = iv_path.
    IF lv_path IS INITIAL.
      lv_path = c_excel_path.
    ENDIF.

    " ── Build header row ──────────────────────────────────────────────
    CONCATENATE
      'Carrier'   c_tab
      'Airline'   c_tab
      'Conn.'     c_tab
      'Flight Date' c_tab
      'From'      c_tab
      'To'        c_tab
      'Price'     c_tab
      'Currency'  c_tab
      'Seats Cap' c_tab
      'Seats Occ' c_tab
      'Load %'    c_tab
      'Est. Revenue' c_tab
      'Distance'  c_tab
      'Unit'      c_tab
      'Price Tier'
      INTO lv_line.
    APPEND lv_line TO lt_output.

    " ── Build data rows ───────────────────────────────────────────────
    LOOP AT it_display ASSIGNING FIELD-SYMBOL(<row>).
      DATA(lv_tier) = SWITCH string(
        <row>-light
        WHEN 'G' THEN 'HIGH (>= 800)'
        WHEN 'Y' THEN 'MID  (300-799)'
        ELSE          'LOW  (< 300)' ).

      CONCATENATE
        <row>-carrid        c_tab
        <row>-carrname      c_tab
        <row>-connid        c_tab
        <row>-fldate        c_tab
        <row>-airpfrom      c_tab
        <row>-airpto        c_tab
        <row>-price         c_tab
        <row>-currency      c_tab
        <row>-seatsmax      c_tab
        <row>-seatsocc      c_tab
        <row>-seats_pct     c_tab
        <row>-revenue       c_tab
        <row>-distance      c_tab
        <row>-distid        c_tab
        lv_tier
        INTO lv_line.
      APPEND lv_line TO lt_output.
    ENDLOOP.

    " ── Download via GUI_DOWNLOAD ──────────────────────────────────────
    CALL FUNCTION 'GUI_DOWNLOAD'
      EXPORTING
        filename                = lv_path
        filetype                = 'DAT'    " Excel-compatible format (tab-delimited, opens natively in Excel)
        write_field_separator   = 'X'
        codepage                = '4110'    " UTF-8 compatible
        confirm_overwrite       = abap_true
      TABLES
        data_tab                = lt_output
      EXCEPTIONS
        file_write_error        = 1
        no_batch                = 2
        gui_refuse_filetransfer = 3
        OTHERS                  = 4.

    IF sy-subrc = 0.
      MESSAGE |Excel export successful: { lv_path }| TYPE 'S'.
    ELSE.
      MESSAGE |Excel export failed (RC={ sy-subrc }). Check path: { lv_path }|
              TYPE 'W'.
    ENDIF.
  ENDMETHOD.
ENDCLASS.

*======================================================================*
* CLASS: ZCL_AIRLINE_ALV_HANDLER  (ALV Event Handler)
*======================================================================*
CLASS zcl_airline_alv_handler DEFINITION.
  PUBLIC SECTION.
    DATA: mt_display    TYPE STANDARD TABLE OF ty_flight_display,
          ms_analytics  TYPE ty_analytics,
          mo_grid       TYPE REF TO cl_gui_alv_grid,
          mv_excel_path TYPE string.

    METHODS:
      on_toolbar
        FOR EVENT toolbar OF cl_gui_alv_grid
        IMPORTING e_object e_interactive,

      on_user_command
        FOR EVENT user_command OF cl_gui_alv_grid
        IMPORTING e_ucomm,

      on_double_click
        FOR EVENT double_click OF cl_gui_alv_grid
        IMPORTING e_row e_column.

  PRIVATE SECTION.
    METHODS:
      show_analytics_popup,
      show_flight_detail_popup
        IMPORTING is_flight TYPE ty_flight_display,
      do_excel_export.
ENDCLASS.

CLASS zcl_airline_alv_handler IMPLEMENTATION.

  " ── Toolbar ─────────────────────────────────────────────────────────
  METHOD on_toolbar.
    " Separator before custom buttons
    DATA(ls_sep) = VALUE stb_button( butn_type = 3 ).
    APPEND ls_sep TO e_object->mt_toolbar.

    " Refresh
    APPEND VALUE stb_button(
      function  = c_btn_refresh
      icon      = icon_refresh
      text      = 'Refresh'
      quickinfo = 'Re-fetch flight data'
      butn_type = 0 ) TO e_object->mt_toolbar.

    " Separator
    APPEND ls_sep TO e_object->mt_toolbar.

    " Export to Excel
    APPEND VALUE stb_button(
      function  = c_btn_excel
      icon      = icon_export
      text      = 'Export Excel'
      quickinfo = 'Download data as XLS file'
      butn_type = 0 ) TO e_object->mt_toolbar.

    " Analytics Popup
    APPEND VALUE stb_button(
      function  = c_btn_analytics
      icon      = icon_display
      text      = 'Analytics'
      quickinfo = 'Show analytics summary dashboard'
      butn_type = 0 ) TO e_object->mt_toolbar.
  ENDMETHOD.

  " ── User Command ────────────────────────────────────────────────────
  METHOD on_user_command.
    CASE e_ucomm.
      WHEN c_btn_refresh.
        SUBMIT (c_prog_name) AND RETURN.

      WHEN c_btn_excel.
        do_excel_export( ).

      WHEN c_btn_analytics.
        show_analytics_popup( ).
    ENDCASE.
  ENDMETHOD.

  " ── Double Click Drill-Down ──────────────────────────────────────────
  " Drill-down navigation implemented via on_double_click event handler.
  " Architecture is expandable to transaction-level navigation (e.g.
  " CALL TRANSACTION 'FB03' or custom Z-transaction with SUBMIT).
  METHOD on_double_click.
    CHECK e_row-index > 0.

    READ TABLE mt_display INDEX e_row-index
      ASSIGNING FIELD-SYMBOL(<sel>).
    IF sy-subrc <> 0. RETURN. ENDIF.

    " Show detailed flight record popup (drill-down view)
    " Expandable: replace with CALL TRANSACTION for live navigation
    show_flight_detail_popup( <sel> ).
  ENDMETHOD.

  " ── Private: Analytics Popup ─────────────────────────────────────────
  METHOD show_analytics_popup.
    " ── Identify Top Airline (WOW feature: real analytics insight) ──
    DATA lv_top_airline TYPE string.
    lv_top_airline = |{ ms_analytics-top_airline } ({ ms_analytics-top_carr_count } flights)|.

    " ── POPUP_TO_DISPLAY_TEXT: clean, structured, professional look ──
    " Each textline maps to one visible row — no raw table juggling needed.
    CALL FUNCTION 'POPUP_TO_DISPLAY_TEXT'
      EXPORTING
        titel     = 'Analytics Summary — Airline Dashboard'
        textline1 = |Total Flights  : { ms_analytics-total_flights }|
        textline2 = |Average Price  : { ms_analytics-avg_price CURRENCY = 'USD' } USD|
        textline3 = |Total Revenue  : { ms_analytics-total_revenue CURRENCY = 'USD' } USD|
        textline4 = |Avg Load Factor: { ms_analytics-avg_load_pct }%   Max: { ms_analytics-max_price }  Min: { ms_analytics-min_price }|
        textline5 = |Top Airline    : { lv_top_airline }|
        textline6 = |Price Tiers    : High { ms_analytics-high_count } flights  Mid { ms_analytics-mid_count }  Low { ms_analytics-low_count }|.

    IF sy-subrc <> 0.
      " Fallback: plain MESSAGE if FM unavailable
      MESSAGE |Flights: { ms_analytics-total_flights } | Avg: { ms_analytics-avg_price CURRENCY = 'USD' } | Top: { lv_top_airline }|
              TYPE 'I'.
    ENDIF.
  ENDMETHOD.

  " ── Private: Flight Detail Popup ────────────────────────────────────
  METHOD show_flight_detail_popup.
    DATA: lt_lines TYPE TABLE OF tline,
          ls_line  TYPE tline.

    DEFINE _fline.
      CLEAR ls_line.
      ls_line-tdformat = &1.
      ls_line-tdline   = &2.
      APPEND ls_line TO lt_lines.
    END-OF-DEFINITION.

    DATA(lv_tier) = SWITCH string(
      is_flight-light
      WHEN 'G' THEN 'HIGH PRICE (Premium)'
      WHEN 'Y' THEN 'MID PRICE  (Standard)'
      ELSE          'LOW PRICE  (Budget)' ).

    _fline '/' '════════════════════════════════════════════'.
    _fline '/' '   FLIGHT DETAIL — DRILL-DOWN VIEW'.
    _fline '/' '════════════════════════════════════════════'.
    _fline ' ' ' '.
    _fline '/' '  CARRIER INFO'.
    _fline '/' '  ────────────────────────────────────────'.
    _fline ' ' |  Airline Code    : { is_flight-carrid }|.
    _fline ' ' |  Airline Name    : { is_flight-carrname }|.
    _fline ' ' |  Connection ID   : { is_flight-connid }|.
    _fline ' ' ' '.
    _fline '/' '  FLIGHT DETAILS'.
    _fline '/' '  ────────────────────────────────────────'.
    _fline ' ' |  Flight Date     : { is_flight-fldate DATE = USER }|.
    _fline ' ' |  Route           : { is_flight-airpfrom } ──► { is_flight-airpto }|.
    _fline ' ' |  Distance        : { is_flight-distance } { is_flight-distid }|.
    _fline ' ' ' '.
    _fline '/' '  PRICING & CAPACITY'.
    _fline '/' '  ────────────────────────────────────────'.
    _fline ' ' |  Ticket Price    : { is_flight-price CURRENCY = is_flight-currency } { is_flight-currency }|.
    _fline ' ' |  Price Tier      : { lv_tier }|.
    _fline ' ' |  Total Capacity  : { is_flight-seatsmax } seats|.
    _fline ' ' |  Seats Occupied  : { is_flight-seatsocc } seats ({ is_flight-seats_pct }%)|.
    _fline ' ' |  Est. Revenue    : { is_flight-revenue CURRENCY = is_flight-currency } { is_flight-currency }|.
    _fline '/' '════════════════════════════════════════════'.

    DATA lv_answer TYPE c.
    CALL FUNCTION 'POPUP_WITH_TABLE'
      EXPORTING
        endpos_col   = 60
        endpos_row   = 24
        startpos_col = 10
        startpos_row = 3
        titletext    = |Flight Detail: { is_flight-carrid }-{ is_flight-connid } on { is_flight-fldate DATE = USER }|
      IMPORTING
        choise       = lv_answer
      TABLES
        valuetab     = lt_lines
      EXCEPTIONS
        OTHERS       = 1.

    IF sy-subrc <> 0.
      " Fallback
      DATA(lv_msg) =
        |{ is_flight-carrname } ({ is_flight-carrid }) / { is_flight-connid }| &&
        | | && |{ is_flight-airpfrom }→{ is_flight-airpto }| &&
        | | && |{ is_flight-fldate DATE = USER }| &&
        | | && |Price: { is_flight-price CURRENCY = is_flight-currency }| &&
        | | && |Load: { is_flight-seats_pct }%|.
      MESSAGE lv_msg TYPE 'I'.
    ENDIF.
  ENDMETHOD.

  " ── Private: Excel Export ───────────────────────────────────────────
  METHOD do_excel_export.
    zcl_airline_excel_exporter=>export(
      it_display = mt_display
      iv_path    = mv_excel_path ).
  ENDMETHOD.
ENDCLASS.

*======================================================================*
* CLASS: ZCL_AIRLINE_PRESENTER  (Presentation Layer)
*======================================================================*
CLASS zcl_airline_presenter DEFINITION FINAL.
  PUBLIC SECTION.
    CLASS-METHODS:
      build_field_catalog
        RETURNING VALUE(rt_fcat)   TYPE lvc_t_fcat,

      build_layout
        RETURNING VALUE(rs_layout) TYPE lvc_s_layo,

      build_sort
        RETURNING VALUE(rt_sort)   TYPE lvc_t_sort.
ENDCLASS.

CLASS zcl_airline_presenter IMPLEMENTATION.

  METHOD build_field_catalog.
    DATA lt_fcat TYPE lvc_t_fcat.
    DATA ls_fc   TYPE lvc_s_fcat.

    " ── Helper: append a catalog entry ──────────────────────────────
    DEFINE _fc.
      CLEAR ls_fc.
      ls_fc-fieldname = &1.
      ls_fc-coltext   = &2.
      ls_fc-outputlen = &3.
      APPEND ls_fc TO lt_fcat.
    END-OF-DEFINITION.

    ls_fc = VALUE lvc_s_fcat( fieldname = 'CARRID'
      coltext = 'Carrier'    outputlen = 8  col_pos = 1 ).     APPEND ls_fc TO lt_fcat.
    ls_fc = VALUE lvc_s_fcat( fieldname = 'CARRNAME'
      coltext = 'Airline'    outputlen = 22 col_pos = 2 ).     APPEND ls_fc TO lt_fcat.
    ls_fc = VALUE lvc_s_fcat( fieldname = 'CONNID'
      coltext = 'Conn.'      outputlen = 8  col_pos = 3 ).     APPEND ls_fc TO lt_fcat.
    ls_fc = VALUE lvc_s_fcat( fieldname = 'FLDATE'
      coltext = 'Flight Date' outputlen = 12 col_pos = 4 ).    APPEND ls_fc TO lt_fcat.
    ls_fc = VALUE lvc_s_fcat( fieldname = 'AIRPFROM'
      coltext = 'From'       outputlen = 8  col_pos = 5 ).     APPEND ls_fc TO lt_fcat.
    ls_fc = VALUE lvc_s_fcat( fieldname = 'AIRPTO'
      coltext = 'To'         outputlen = 8  col_pos = 6 ).     APPEND ls_fc TO lt_fcat.
    ls_fc = VALUE lvc_s_fcat( fieldname = 'PRICE'
      coltext = 'Price'      outputlen = 12 col_pos = 7
      cfieldname = 'CURRENCY' ).                               APPEND ls_fc TO lt_fcat.
    ls_fc = VALUE lvc_s_fcat( fieldname = 'CURRENCY'
      coltext = 'Curr.'      outputlen = 6  col_pos = 8 ).     APPEND ls_fc TO lt_fcat.
    ls_fc = VALUE lvc_s_fcat( fieldname = 'SEATSMAX'
      coltext = 'Capacity'   outputlen = 10 col_pos = 9
      no_zero = abap_true ).                                   APPEND ls_fc TO lt_fcat.
    ls_fc = VALUE lvc_s_fcat( fieldname = 'SEATSOCC'
      coltext = 'Occupied'   outputlen = 10 col_pos = 10
      no_zero = abap_true ).                                   APPEND ls_fc TO lt_fcat.
    ls_fc = VALUE lvc_s_fcat( fieldname = 'SEATS_PCT'
      coltext = 'Load %'     outputlen = 10 col_pos = 11
      decimals_o = '1' ).                                      APPEND ls_fc TO lt_fcat.
    ls_fc = VALUE lvc_s_fcat( fieldname = 'REVENUE'
      coltext = 'Est. Revenue' outputlen = 16 col_pos = 12
      cfieldname = 'CURRENCY' ).                               APPEND ls_fc TO lt_fcat.
    ls_fc = VALUE lvc_s_fcat( fieldname = 'DISTANCE'
      coltext = 'Distance'   outputlen = 10 col_pos = 13 ).    APPEND ls_fc TO lt_fcat.
    ls_fc = VALUE lvc_s_fcat( fieldname = 'DISTID'
      coltext = 'Unit'       outputlen = 6  col_pos = 14 ).    APPEND ls_fc TO lt_fcat.

    " Traffic light icon column
    ls_fc = VALUE lvc_s_fcat(
      fieldname  = 'LIGHT'
      coltext    = 'Price Tier'
      outputlen  = 12
      col_pos    = 15
      icon       = abap_true ).
    APPEND ls_fc TO lt_fcat.

    " Hide technical row-color field
    ls_fc = VALUE lvc_s_fcat(
      fieldname = 'ROWCOLOR'
      tech      = abap_true ).
    APPEND ls_fc TO lt_fcat.

    rt_fcat = lt_fcat.
  ENDMETHOD.

  METHOD build_layout.
    rs_layout = VALUE lvc_s_layo(
      zebra         = abap_true       " Alternating row shading
      cwidth_opt    = 'A'             " Auto-optimize all column widths
      info_fname    = 'ROWCOLOR'      " Row color driven by field
      sel_mode      = 'A'             " Full row selection
      col_opt       = abap_true       " Column optimization active
      grid_title    = 'Smart Airline Analytics Dashboard  |  Double-click a row for details'
      no_rowmark    = abap_false
      stylefname    = ' ' ).
  ENDMETHOD.

  METHOD build_sort.
    APPEND VALUE lvc_s_sort(
      fieldname = 'CARRID'
      up        = abap_true
      subtot    = abap_true ) TO rt_sort.
    APPEND VALUE lvc_s_sort(
      fieldname = 'FLDATE'
      up        = abap_true ) TO rt_sort.
  ENDMETHOD.
ENDCLASS.

*======================================================================*
* GLOBAL REFERENCES  (used by PBO / PAI screen modules)
*======================================================================*
DATA: go_container TYPE REF TO cl_gui_custom_container,
      go_grid      TYPE REF TO cl_gui_alv_grid,
      go_handler   TYPE REF TO zcl_airline_alv_handler,
      gt_display   TYPE STANDARD TABLE OF ty_flight_display,
      gs_analytics TYPE ty_analytics.

*======================================================================*
* MAIN — START-OF-SELECTION
*======================================================================*
START-OF-SELECTION.

  " ── Input Validation ──────────────────────────────────────────────
  IF pa_pmin > pa_pmax.
    MESSAGE 'Minimum price cannot exceed maximum price.' TYPE 'E'.
  ENDIF.

  " ── Data Fetch ────────────────────────────────────────────────────
  DATA(lt_raw) = zcl_airline_data_fetcher=>fetch(
    it_carr = so_carr[]
    it_date = so_date[]
    iv_pmin = pa_pmin
    iv_pmax = pa_pmax ).

  IF lt_raw IS INITIAL.
    MESSAGE 'No flight data found for the given selection criteria.' TYPE 'S'
            DISPLAY LIKE 'W'.
    LEAVE LIST-PROCESSING.
  ENDIF.

  " ── Business Logic ────────────────────────────────────────────────
  gt_display   = zcl_airline_biz_logic=>enrich( lt_raw ).
  gs_analytics = zcl_airline_biz_logic=>compute_analytics( gt_display ).

  " ── Status bar summary ────────────────────────────────────────────
  MESSAGE |{ gs_analytics-total_flights } flights loaded. | &&
          |Revenue: { gs_analytics-total_revenue CURRENCY = 'USD' } | &&
          |Avg Price: { gs_analytics-avg_price CURRENCY = 'USD' }. | &&
          |Double-click any row for details.|
    TYPE 'S'.

  " ── Display Screen ────────────────────────────────────────────────
  CALL SCREEN 100.

*======================================================================*
* SCREEN 0100 — PBO Module
* Note: Screen 100 must be defined in SE51 with a custom container
*       control named 'MAIN_CONTAINER' filling the full screen area.
*       GUI status 'MAIN' must include BACK, EXIT, CANCEL.
*======================================================================*
MODULE pbo_0100 OUTPUT.
  SET PF-STATUS 'MAIN'.
  SET TITLEBAR  'T001' WITH 'Smart Airline Analytics Dashboard v2.0'.

  IF go_container IS NOT BOUND.

    " ── Create ALV container & grid ───────────────────────────────
    go_container = NEW cl_gui_custom_container(
      container_name = 'MAIN_CONTAINER'
      repid          = c_prog_name
      dynnr          = '0100' ).

    go_grid = NEW cl_gui_alv_grid(
      i_parent = go_container ).

    " ── Create event handler, populate data references ────────────
    go_handler = NEW zcl_airline_alv_handler( ).
    go_handler->mt_display    = gt_display.
    go_handler->ms_analytics  = gs_analytics.
    go_handler->mo_grid       = go_grid.
    go_handler->mv_excel_path = pa_xls.

    " ── Register events ───────────────────────────────────────────
    SET HANDLER go_handler->on_toolbar      FOR go_grid.
    SET HANDLER go_handler->on_user_command FOR go_grid.
    SET HANDLER go_handler->on_double_click FOR go_grid.

    " ── Build catalog, layout, sort and display ───────────────────
    DATA(lt_fcat)   = zcl_airline_presenter=>build_field_catalog( ).
    DATA(ls_layout) = zcl_airline_presenter=>build_layout( ).
    DATA(lt_sort)   = zcl_airline_presenter=>build_sort( ).

    go_grid->set_table_for_first_display(
      EXPORTING
        is_layout       = ls_layout
        it_sort         = lt_sort
        i_save          = 'A'       " Allow layout save (user + global)
      CHANGING
        it_outtab       = gt_display
        it_fieldcatalog = lt_fcat ).

  ENDIF.
ENDMODULE.

*======================================================================*
* SCREEN 0100 — PAI Module
*======================================================================*
MODULE pai_0100 INPUT.
  DATA lv_ucomm TYPE sy-ucomm.
  lv_ucomm = sy-ucomm.
  CLEAR sy-ucomm.

  CASE lv_ucomm.
    WHEN 'BACK' OR 'EXIT' OR 'CANCEL'.
      LEAVE PROGRAM.
  ENDCASE.
ENDMODULE.

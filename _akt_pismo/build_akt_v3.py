# -*- coding: utf-8 -*-
"""Сборка акта о повреждении груза на фирменном бланке письма АО «Завод ПРОТОН» (v3)."""
from docx import Document
from docx.oxml import parse_xml
from docx.oxml.ns import nsdecls, qn

TPL = r"C:\YandexDisk\AI\Документы\Бланки\Бланк письма.docx"
OUT = r"C:\YandexDisk\AI\Документы\Акт о повреждении груза при транспортировке от 13.10.2026.docx"

SZ = '<w:sz w:val="28"/><w:szCs w:val="28"/>'      # 14 pt, как в бланке
IND = 709                                          # абзацный отступ бланка
NB = '\u00a0'                                      # неразрывный пробел


def esc(t):
    return t.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def run(text, b=False):
    rpr = '<w:rPr>' + ('<w:b/>' if b else '') + SZ + '</w:rPr>'
    return f'<w:r>{rpr}<w:t xml:space="preserve">{esc(text)}</w:t></w:r>'


def run_tab():
    return f'<w:r><w:rPr>{SZ}</w:rPr><w:tab/></w:r>'


def para(runs, jc='both', first=IND, left=None, hanging=None, tabs=None,
         before=0, after=0, line=276, keep_next=False):
    ind = ''
    if left is not None:
        ind += f' w:left="{left}"'
    if hanging is not None:
        ind += f' w:hanging="{hanging}"'
    elif first:
        ind += f' w:firstLine="{first}"'
    ind_xml = f'<w:ind{ind}/>' if ind else ''
    tabs_xml = ''
    if tabs:
        tabs_xml = '<w:tabs>' + ''.join(
            f'<w:tab w:val="right" w:pos="{p}"/>' for p in tabs) + '</w:tabs>'
    jc_xml = f'<w:jc w:val="{jc}"/>' if jc else ''
    spacing = (f'<w:spacing w:before="{before}" w:after="{after}"'
               f' w:line="{line}" w:lineRule="auto"/>')
    keep = '<w:keepNext/>' if keep_next else ''
    return parse_xml(
        f'<w:p {nsdecls("w")}><w:pPr>{keep}{tabs_xml}{spacing}{ind_xml}{jc_xml}'
        f'</w:pPr>{runs}</w:p>')


def cell(text_runs, width, jc='left', valign='center'):
    tcpr = (f'<w:tcPr><w:tcW w:w="{width}" w:type="dxa"/>'
            f'<w:vAlign w:val="{valign}"/></w:tcPr>')
    p = para(text_runs, jc=jc, first=0, line=240)
    return f'<w:tc>{tcpr}{p.xml}</w:tc>'


def sig_table(rows):
    borders = ''.join(
        f'<w:{e} w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
        for e in ('top', 'left', 'bottom', 'right', 'insideH', 'insideV'))
    w1, w2 = 6800, 3381
    grid = f'<w:tblGrid><w:gridCol w:w="{w1}"/><w:gridCol w:w="{w2}"/></w:tblGrid>'
    trs = ''
    for left_text, right_text, bold in rows:
        h = 340 if bold else 440
        trs += ('<w:tr><w:trPr>'
                f'<w:trHeight w:val="{h}"/>'
                '</w:trPr>'
                + cell(run(left_text, bold), w1,
                       jc='center' if bold else 'left', valign='center')
                + cell(run(right_text, bold), w2,
                       jc='center', valign='center')
                + '</w:tr>')
    return parse_xml(
        f'<w:tbl {nsdecls("w")}>'
        '<w:tblPr>'
        f'<w:tblW w:w="{w1 + w2}" w:type="dxa"/>'
        '<w:tblInd w:w="139" w:type="dxa"/>'
        f'<w:tblBorders>{borders}</w:tblBorders>'
        '<w:tblLayout w:type="fixed"/>'
        '<w:tblLook w:val="0000" w:firstRow="0" w:lastRow="0" '
        'w:firstColumn="0" w:lastColumn="0" w:noHBand="0" w:noVBand="0"/>'
        '</w:tblPr>'
        f'{grid}{trs}</w:tbl>')


doc = Document(TPL)
body = doc.element.body
sect = body.find(qn('w:sectPr'))
children = list(body)

# --- 1. Убираем демонстрационный текст письма, оставляя шапку, реквизиты и адресата
last_bm = max(i for i, c in enumerate(children) if c.tag == qn('w:bookmarkEnd'))
for c in children[last_bm + 1:]:
    if c is not sect:
        body.remove(c)

# --- 2. Исходящий номер: дата акта; строку «На № …» убираем (входящего письма нет)
t_reg = doc.tables[1]
cell0 = t_reg.rows[0].cells[0]
ps = cell0.paragraphs
p_num = ps[0]
for extra in p_num.runs[1:]:
    extra._r.getparent().remove(extra._r)
p_num.runs[0].text = 'Исх. №___________ от 13.10.2026г.'
ps[1]._p.getparent().remove(ps[1]._p)


def add(el):
    sect.addprevious(el)


# --- 3. Заголовок акта
add(para(run(f'АКТ №{NB}_____', b=True), jc='center', first=0,
         before=120, after=0, keep_next=True))
add(para(run('о повреждении груза при транспортировке'),
         jc='center', first=0, after=120, keep_next=True))

# --- 4. Место и дата
add(para(run(f'г.{NB}__________________') + run_tab()
         + run(f'«13»{NB}октября 2026{NB}г.'),
         jc='left', first=0, tabs=[9746], after=120, keep_next=True))

# --- 5. Состав комиссии
add(para(run('Настоящий акт составлен комиссией в составе:'), after=0, keep_next=True))
add(para(run('1. Логинов Владимир Борисович — ведущий конструктор;'), after=0))
add(para(run('2. Чиликин Евгений Сергеевич — инженер по наладке '
             'и испытаниям;'), after=0))
add(para(run('3. Меркулов Сергей Вячеславович — программист.'), after=120))


def heading(text):
    add(para(run(text, b=True), jc='left', first=0, before=180, after=60,
             keep_next=True))


def body_par(text, **kw):
    add(para(run(text), **kw))


def bullet(text):
    add(para(run('– ' + text), left=IND * 2, hanging=IND, after=0,
             **{'first': 0}))


# --- 6. Раздел 1
heading('1. Сведения о получении груза')
body_par(f'13{NB}октября 2026{NB}года в 16{NB}часов 55{NB}минут был получен груз '
         f'по транспортной накладной №{NB}УК0002488КМ от 08.10.2026{NB}г.')
body_par('В связи с конструктивными особенностями упаковки и невозможностью её вскрытия '
         'без применения специального инструмента осмотр содержимого непосредственно при '
         'получении груза не представлялся возможным.')
body_par('Вскрытие упаковки было произведено на территории предприятия в присутствии '
         'вышеуказанной комиссии.')

# --- 7. Раздел 2
heading('2. Результаты осмотра')
add(para(run('В ходе комиссионного вскрытия упаковки и последующего визуального осмотра '
             'содержимого было установлено ')
         + run('полное нарушение целостности груза', b=True) + run('.')))
body_par('Выявленные повреждения свидетельствуют о существенном нарушении сохранности '
         'груза и невозможности признания его полученным в надлежащем состоянии.')
body_par('Характер и степень повреждений подлежат дополнительной фиксации и, при '
         'необходимости, технической оценке.')

# --- 8. Раздел 3
heading('3. Заключение комиссии')
body_par('На основании проведённого осмотра комиссия установила:', keep_next=True)
bullet(f'Груз, полученный по транспортной накладной №{NB}УК0002488КМ '
       f'от 08.10.2026{NB}г., имеет существенные повреждения.')
bullet('Целостность груза полностью нарушена.')
bullet('Повреждения были обнаружены непосредственно после вскрытия транспортной упаковки '
       'на территории предприятия.')
bullet('Установить точное время и обстоятельства возникновения повреждений на основании '
       'одного визуального осмотра не представляется возможным.')
body_par('')
body_par('Настоящий акт составлен в целях документального подтверждения факта обнаружения '
         'повреждений груза, фиксации его состояния и последующего предъявления претензии '
         'ответственным лицам в установленном порядке.')

# --- 9. Раздел 4: подписи
heading('4. Подписи членов комиссии')
add(sig_table([
    ('Должность, Ф. И. О.', 'Подпись', True),
    (f'Ведущий конструктор Логинов В.{NB}Б.', '______________', False),
    (f'Генеральный директор Смирнов А.{NB}С.', '______________', False),
]))

# --- 10. Приложения
add(para(run('Приложения: ', b=True)
         + run('фотоматериалы, подтверждающие состояние груза и характер выявленных '
               'повреждений, при наличии.'), before=240))
add(para('', first=0))

doc.save(OUT)
print('OK ->', OUT)

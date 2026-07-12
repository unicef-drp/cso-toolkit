<!-- vendored from datalib-unicef config/grammar.md @ v0.7.0 — do not hand-edit; refresh via _manifest.yml -->

```
<root>/<CCC>/                                            1 token
<root>/<CCC>/<CCC>_<YYYY>_<SSSS>/                        3 tokens ("_"-separated)
  master vintage:     <CCC>_<YYYY>_<SSSS>_v<MM>_M        5 tokens
  adaptation vintage: <CCC>_<YYYY>_<SSSS>_v<MM>_M_v<AA>_A_<HHHH>   8 tokens
inside a vintage:     Data/{Original,Stata,R,Other}  Doc/  Programs/
data files:           <vintage-folder-name>_<module>.dta   under Data/Stata/
```

Token positions when splitting on `_`: 1 country, 2 year, 3 survey,
4 master vintage (`v01`), 6 adaptation vintage, 8 collection.

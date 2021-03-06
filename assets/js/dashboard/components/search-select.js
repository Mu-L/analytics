import React, {useState, useCallback} from 'react'
import {useCombobox} from 'downshift'
import classNames from 'classnames'
import debounce from 'debounce-promise'

function selectInputText(e) {
  e.target.select()
}

function ChevronDown() {
  return (
    <svg className="h-5 w-5" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 20 20">
      <path stroke="#6B7280" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.5" d="M6 8l4 4 4-4"/>
    </svg>
  )
}

function Spinner() {
  return (
    <svg className="animate-spin h-4 w-4 text-indigo-500" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"></circle>
      <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
    </svg>
  )
}

export default function SearchSelect(props) {
  const [items, setItems] = useState([])
  const [loading, setLoading] = useState(false)
  const [initialLoadComplete, setInitialLoadComplete] = useState(false)

  function fetchOptions({inputValue, isOpen}) {
    setLoading(isOpen)

    return props.fetchOptions(inputValue).then((loadedItems) => {
      setLoading(false)
      setItems(loadedItems)
    })
  }

  const debouncedFetchOptions = useCallback(debounce(fetchOptions, 200), [])

  const {
    isOpen,
    inputValue,
    getToggleButtonProps,
    getLabelProps,
    getMenuProps,
    getInputProps,
    getComboboxProps,
    highlightedIndex,
    getItemProps,
    selectItem,
    closeMenu,
    setInputValue
  } = useCombobox({
    items: items,
    onInputValueChange: (changes) => {
      debouncedFetchOptions(changes)
      props.onInput(changes.inputValue)
    },
    initialSelectedItem: props.initialSelectedItem,
    onIsOpenChange: ({inputValue}) => {
      if (!initialLoadComplete) {
        fetchOptions({inputValue: inputValue, isOpen: true}).then(() => {
          setInitialLoadComplete(true)
        })
      }
    }
  })

  function keydown(e) {
    if (e.ctrlKey || e.metaKey || e.shiftKey || e.altKey || e.isComposing || e.keyCode === 229) return

    if (e.key == 'Enter' && isOpen && highlightedIndex === -1) {
      closeMenu()
      e.preventDefault()
    }
  }

  return (
    <div className="mt-1 relative">
      <div className="relative rounded-md shadow-sm" {...getToggleButtonProps()} {...getComboboxProps()}>
        <input {...getInputProps({onKeyDown: keydown})} onFocus={selectInputText} placeholder={props.placeholder} type="text" className={classNames('w-full pr-10 border-gray-300 dark:border-gray-700 hover:border-gray-400 dark:hover:border-gray-200 focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm rounded-md dark:bg-gray-900 dark:text-gray-300 block', {'cursor-pointer': inputValue === '' && !isOpen})}  />
        <div className="absolute inset-y-0 right-0 flex items-center pr-2 pointer-events-none">
          { !loading && <ChevronDown /> }
          { loading && <Spinner /> }
        </div>
      </div>
      <div {...getMenuProps()}>
        { isOpen &&
        <ul className="absolute z-10 mt-1 w-full bg-white dark:bg-gray-900 shadow-lg max-h-60 rounded-md py-1 text-base ring-1 ring-black ring-opacity-5 overflow-auto focus:outline-none sm:text-sm">
          { !loading && items.length == 0 &&
          <li className="text-gray-500 select-none py-2 px-3">No matches found in the current dashboard. Try selecting a different time range or searching for something different</li>
          }
          { loading && items.length == 0 &&
            <li className="text-gray-500 select-none py-2 px-3">Loading options...</li>
          }

          {
            items.map((item, index) => (
              <li className={classNames("cursor-pointer select-none relative py-2 pl-3 pr-9", {'text-white bg-indigo-600': highlightedIndex === index, 'text-gray-900 dark:text-gray-100': highlightedIndex !== index})}
                key={`${item}${index}`}
                {...getItemProps({ item, index })}
              >
                {item}
              </li>
            ))
          }
        </ul>
        }
      </div>
    </div>
  )
}
